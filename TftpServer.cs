using System.Net;
using System.Net.Sockets;
using System.Text;

namespace PxeTftp;

/// <summary>
/// Minimal, read-only, async TFTP server (RFC 1350) with option negotiation
/// (RFC 2347/2348/2349) and windowed transfers (RFC 7440).
/// Intended for PXE boot file serving only: RRQ is supported, WRQ is refused.
/// </summary>
public sealed class TftpServer : IAsyncDisposable
{
    private const short OpRrq = 1;
    private const short OpWrq = 2;
    private const short OpData = 3;
    private const short OpAck = 4;
    private const short OpError = 5;
    private const short OpOack = 6;

    private const short ErrNotDefined = 0;
    private const short ErrFileNotFound = 1;
    private const short ErrAccessViolation = 2;
    private const short ErrIllegalOperation = 4;

    public event EventHandler<TftpLogEventArgs>? LogMessage;
    public event EventHandler<TftpTransferEventArgs>? TransferComplete;
    public event EventHandler<TftpTransferEventArgs>? TransferFailed;

    private readonly string _rootPath;
    private readonly int _maxBlockSize;
    private readonly int _maxWindowSize;
    private readonly int _defaultTimeoutSeconds;
    private readonly int _maxRetries;
    private readonly bool _disableOptions;

    private UdpClient? _listener;
    private CancellationTokenSource? _cts;
    private Task? _listenTask;
    private int _activeTransfers;

    /// <param name="rootPath">Directory that TFTP RRQ file paths are resolved against. Clients cannot escape it.</param>
    /// <param name="maxBlockSize">Upper bound offered during blksize negotiation (RFC 2348). 1428-1468 is a safe MTU-friendly value.</param>
    /// <param name="maxWindowSize">Upper bound offered during windowsize negotiation (RFC 7440). 1 disables windowing (classic stop-and-wait).</param>
    /// <param name="defaultTimeoutSeconds">Retransmit timeout used unless the client negotiates a different one.</param>
    /// <param name="maxRetries">Number of retransmits of the current window before a transfer is abandoned.</param>
    /// <param name="disableOptions">
    /// If true, never negotiate options and never send an OACK, even if the client requests them -
    /// pure RFC 1350 behavior (512-byte blocks, no windowing). Some PXE firmware and boot loaders
    /// (including plain bootmgr.efi's own internal TFTP client, as opposed to the firmware bootstrap
    /// loader that first fetched bootmgr.efi itself) time out waiting for an OACK reply and silently
    /// fail rather than falling back to a plain RRQ the way the initial firmware NBP fetch does. If
    /// boot files transfer fine standalone but a chained loader fails to find its next file, try this.
    /// </param>
    public TftpServer(string rootPath, int maxBlockSize = 1428, int maxWindowSize = 4,
        int defaultTimeoutSeconds = 3, int maxRetries = 5, bool disableOptions = false)
    {
        _rootPath = Path.GetFullPath(rootPath);
        _maxBlockSize = Math.Clamp(maxBlockSize, 8, 65464);
        _maxWindowSize = Math.Max(1, maxWindowSize);
        _defaultTimeoutSeconds = Math.Max(1, defaultTimeoutSeconds);
        _maxRetries = Math.Max(1, maxRetries);
        _disableOptions = disableOptions;
    }

    public bool IsRunning => _listenTask is { IsCompleted: false };
    public int ActiveTransfers => _activeTransfers;

    public void Start(int port = 69)
    {
        if (IsRunning) throw new InvalidOperationException("TFTP server is already running.");
        if (!Directory.Exists(_rootPath))
            throw new DirectoryNotFoundException($"TFTP root path does not exist: {_rootPath}");

        _listener = new UdpClient(new IPEndPoint(IPAddress.Any, port));
        _cts = new CancellationTokenSource();
        _listenTask = Task.Run(() => ListenLoopAsync(_cts.Token));
        Log(TftpLogLevel.Info, $"TFTP server started on UDP/{port}, root '{_rootPath}'.");
    }

    public async Task StopAsync()
    {
        if (_cts is null) return;
        _cts.Cancel();
        try
        {
            _listener?.Close();
            if (_listenTask is not null) await _listenTask.ConfigureAwait(false);
        }
        catch (OperationCanceledException) { /* expected on shutdown */ }
        finally
        {
            _listener?.Dispose();
            _listener = null;
            Log(TftpLogLevel.Info, "TFTP server stopped.");
        }
    }

    public async ValueTask DisposeAsync() => await StopAsync().ConfigureAwait(false);

    private async Task ListenLoopAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            UdpReceiveResult result;
            try
            {
                result = await _listener!.ReceiveAsync(token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (ObjectDisposedException)
            {
                break;
            }
            catch (SocketException ex)
            {
                Log(TftpLogLevel.Warning, $"Socket error on listener: {ex.Message}");
                continue;
            }

            // Fire-and-forget per client; each transfer gets its own ephemeral-port UdpClient,
            // exactly as classic TFTP requires.
            _ = Task.Run(() => HandleRequestAsync(result.Buffer, result.RemoteEndPoint, token), token);
        }
    }

    private async Task HandleRequestAsync(byte[] request, IPEndPoint clientEndPoint, CancellationToken serverToken)
    {
        short opcode = ReadInt16(request, 0);

        if (opcode == OpWrq)
        {
            await SendErrorAsync(clientEndPoint, ErrAccessViolation, "Write requests are not supported (read-only server).");
            return;
        }

        if (opcode != OpRrq)
        {
            await SendErrorAsync(clientEndPoint, ErrIllegalOperation, "Only RRQ is supported.");
            return;
        }

        if (!TryParseRrq(request, out var fileName, out var mode, out var options, out var parseError))
        {
            await SendErrorAsync(clientEndPoint, ErrIllegalOperation, parseError ?? "Malformed request.");
            return;
        }

        if (!string.Equals(mode, "octet", StringComparison.OrdinalIgnoreCase) &&
            !string.Equals(mode, "netascii", StringComparison.OrdinalIgnoreCase))
        {
            await SendErrorAsync(clientEndPoint, ErrIllegalOperation, $"Unsupported mode '{mode}'.");
            return;
        }

        string fullPath;
        try
        {
            fullPath = ResolveSafePath(fileName);
        }
        catch (Exception)
        {
            Log(TftpLogLevel.Warning, $"Rejected path traversal attempt from {clientEndPoint}: '{fileName}'.");
            await SendErrorAsync(clientEndPoint, ErrAccessViolation, "Access violation.");
            return;
        }

        if (!File.Exists(fullPath))
        {
            Log(TftpLogLevel.Warning, $"{clientEndPoint} requested missing file '{fileName}'.");
            await SendErrorAsync(clientEndPoint, ErrFileNotFound, "File not found.");
            return;
        }

        Interlocked.Increment(ref _activeTransfers);
        var sw = System.Diagnostics.Stopwatch.StartNew();
        try
        {
            await RunTransferAsync(clientEndPoint, fileName, fullPath, options, serverToken).ConfigureAwait(false);
            sw.Stop();
        }
        catch (SocketException ex) when (ex.SocketErrorCode == SocketError.ConnectionReset)
        {
            sw.Stop();
            // This fires when the client abandons a session (its own aggressive internal
            // retry/timeout) and the OS surfaces the resulting ICMP port-unreachable as a
            // reset on our connected socket. Expected, benign behavior for PXE firmware
            // that retries very fast - not a real error - the client typically succeeds
            // moments later on a fresh port, as long as later log lines show a Completed
            // for the same file.
            Log(TftpLogLevel.Warning, $"{clientEndPoint} abandoned its session for '{fileName}' (client retried before we finished replying).");
            TransferFailed?.Invoke(this, new TftpTransferEventArgs(clientEndPoint, fileName, 0, sw.Elapsed, ex.Message));
        }
        catch (Exception ex)
        {
            sw.Stop();
            Log(TftpLogLevel.Error, $"Transfer of '{fileName}' to {clientEndPoint} failed: {ex.Message}");
            TransferFailed?.Invoke(this, new TftpTransferEventArgs(clientEndPoint, fileName, 0, sw.Elapsed, ex.Message));
        }
        finally
        {
            Interlocked.Decrement(ref _activeTransfers);
        }
    }

    private async Task RunTransferAsync(IPEndPoint clientEndPoint, string fileName, string fullPath,
        Dictionary<string, string> requestedOptions, CancellationToken serverToken)
    {
        using var fileStream = new FileStream(fullPath, FileMode.Open, FileAccess.Read, FileShare.Read);
        long fileSize = fileStream.Length;

        int blockSize = 512;
        int windowSize = 1;
        int timeoutSeconds = _defaultTimeoutSeconds;
        bool clientWantsOptions = !_disableOptions && requestedOptions.Count > 0;

        var ackedOptions = new Dictionary<string, string>();

        if (clientWantsOptions)
        {
            if (requestedOptions.TryGetValue("blksize", out var blkStr) && int.TryParse(blkStr, out var reqBlk))
            {
                blockSize = Math.Clamp(reqBlk, 8, _maxBlockSize);
                ackedOptions["blksize"] = blockSize.ToString();
            }
            if (requestedOptions.TryGetValue("windowsize", out var winStr) && int.TryParse(winStr, out var reqWin))
            {
                windowSize = Math.Clamp(reqWin, 1, _maxWindowSize);
                ackedOptions["windowsize"] = windowSize.ToString();
            }
            if (requestedOptions.TryGetValue("timeout", out var toStr) && int.TryParse(toStr, out var reqTo))
            {
                timeoutSeconds = Math.Clamp(reqTo, 1, 255);
                ackedOptions["timeout"] = timeoutSeconds.ToString();
            }
            if (requestedOptions.ContainsKey("tsize"))
            {
                ackedOptions["tsize"] = fileSize.ToString();
            }
            // Guard against a client that sent option keys we don't recognize but no
            // known ones matched: don't send an empty OACK, just fall back silently.
            if (ackedOptions.Count == 0) clientWantsOptions = false;
        }

        // Each transfer talks over its own ephemeral-port socket, connected to the client,
        // which is what lets the server run many concurrent transfers on the well-known
        // port 69 listener without them interfering with each other.
        using var session = new UdpClient(0);
        session.Connect(clientEndPoint);
        var timeout = TimeSpan.FromSeconds(timeoutSeconds);

        if (clientWantsOptions)
        {
            var oack = BuildOack(ackedOptions);
            bool oackAcked = false;
            for (int attempt = 1; attempt <= _maxRetries && !oackAcked; attempt++)
            {
                await session.SendAsync(oack, oack.Length);
                var ack = await WaitForAckAsync(session, 0, 0, timeout, serverToken);
                oackAcked = ack is not null;
            }

            if (!oackAcked)
            {
                // Some clients' TFTP stacks won't accept an unsolicited DATA packet as an
                // implicit "options declined" per RFC 2347 - they just go silent. Rather than
                // abort (which only works if the *caller* retries via a fresh, option-less RRQ,
                // which not every network boot loader does), degrade to plain RFC 1350 defaults
                // and keep going on this same session. Worst case this send is also ignored and
                // the transfer times out normally below, same as any other unresponsive client.
                Log(TftpLogLevel.Warning,
                    $"{clientEndPoint} did not acknowledge OACK for '{fileName}' after {_maxRetries} attempts; " +
                    "falling back to plain 512-byte blocks on this same session.");
                blockSize = 512;
                windowSize = 1;
            }
        }

        long totalBlocks = (fileSize + blockSize - 1) / blockSize;
        if (totalBlocks == 0) totalBlocks = 1; // zero-byte file: still send one empty final block

        long highestAcked = 0;
        var buffer = new byte[blockSize];

        while (highestAcked < totalBlocks)
        {
            long windowStart = highestAcked + 1;
            long windowEnd = Math.Min(windowStart + windowSize - 1, totalBlocks);

            for (long block = windowStart; block <= windowEnd; block++)
            {
                int bytesRead = await ReadBlockAsync(fileStream, buffer, block, blockSize);
                var dataPacket = BuildData(block, buffer, bytesRead);
                await session.SendAsync(dataPacket, dataPacket.Length);
            }

            long? ackedBlock = await WaitForAckAsync(session, windowStart, windowEnd, timeout, serverToken);

            if (ackedBlock is null)
            {
                // Timed out waiting on the whole window: RFC 7440 go-back-N, resend from last acked point.
                var retryResult = await RetryWindowAsync(session, fileStream, buffer, blockSize,
                    windowStart, windowEnd, timeout, serverToken);
                if (retryResult is null)
                {
                    Log(TftpLogLevel.Warning, $"{clientEndPoint} timed out on '{fileName}' after {_maxRetries} retries; abandoning transfer.");
                    return;
                }
                highestAcked = retryResult.Value;
            }
            else
            {
                highestAcked = ackedBlock.Value;
            }
        }

        Log(TftpLogLevel.Info, $"Sent '{fileName}' ({fileSize} bytes) to {clientEndPoint}.");
        TransferComplete?.Invoke(this, new TftpTransferEventArgs(clientEndPoint, fileName, fileSize, TimeSpan.Zero));
    }

    /// <summary>Resends the given window up to _maxRetries times. Returns the newly acked block number, or null if retries were exhausted.</summary>
    private async Task<long?> RetryWindowAsync(UdpClient session, FileStream fileStream, byte[] buffer, int blockSize,
        long windowStart, long windowEnd, TimeSpan timeout, CancellationToken serverToken)
    {
        for (int attempt = 1; attempt <= _maxRetries; attempt++)
        {
            for (long block = windowStart; block <= windowEnd; block++)
            {
                int bytesRead = await ReadBlockAsync(fileStream, buffer, block, blockSize);
                var dataPacket = BuildData(block, buffer, bytesRead);
                await session.SendAsync(dataPacket, dataPacket.Length);
            }

            long? ackedBlock = await WaitForAckAsync(session, windowStart, windowEnd, timeout, serverToken);
            if (ackedBlock is not null)
            {
                return ackedBlock.Value;
            }
        }
        return null; // exhausted retries
    }

    private static async Task<int> ReadBlockAsync(FileStream fileStream, byte[] buffer, long blockNumber, int blockSize)
    {
        long offset = (blockNumber - 1) * blockSize;
        if (fileStream.Position != offset) fileStream.Seek(offset, SeekOrigin.Begin);
        int total = 0;
        while (total < blockSize)
        {
            int read = await fileStream.ReadAsync(buffer.AsMemory(total, blockSize - total));
            if (read == 0) break;
            total += read;
        }
        return total;
    }

    /// <summary>
    /// Waits for an ACK whose block number falls within [windowStart, windowEnd] (mod 65536,
    /// which is how TFTP block numbers wrap for files larger than 65535 * blockSize).
    /// Returns the acked block (unwrapped to the long block space) or null on timeout.
    /// </summary>
    private static async Task<long?> WaitForAckAsync(UdpClient session, long windowStart, long windowEnd,
        TimeSpan timeout, CancellationToken serverToken)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(serverToken);
        cts.CancelAfter(timeout);
        try
        {
            while (true)
            {
                var result = await session.ReceiveAsync(cts.Token).ConfigureAwait(false);
                var data = result.Buffer;
                if (data.Length < 4) continue;
                short opcode = ReadInt16(data, 0);
                if (opcode == OpError)
                {
                    return null; // client aborted; treat like a timeout so the caller stops cleanly
                }
                if (opcode != OpAck) continue;

                ushort ackedWire = (ushort)ReadInt16(data, 2);
                long unwrapped = UnwrapBlockNumber(ackedWire, windowEnd);
                if (unwrapped >= windowStart - 1 && unwrapped <= windowEnd)
                    return unwrapped;
                // Stale/duplicate ACK from an earlier window: keep waiting for the real one.
            }
        }
        catch (OperationCanceledException)
        {
            return null;
        }
    }

    /// <summary>Reconstructs the true block number from the 16-bit wire value, assuming progress stays within one window of drift.</summary>
    private static long UnwrapBlockNumber(ushort wireBlock, long referenceHigh)
    {
        long baseValue = referenceHigh - (referenceHigh % 65536);
        long candidate = baseValue + wireBlock;
        if (candidate > referenceHigh + 32768) candidate -= 65536;
        if (candidate < referenceHigh - 32768) candidate += 65536;
        return candidate;
    }

    private async Task SendErrorAsync(IPEndPoint clientEndPoint, short errorCode, string message)
    {
        using var session = new UdpClient(0);
        session.Connect(clientEndPoint);
        var packet = BuildError(errorCode, message);
        await session.SendAsync(packet, packet.Length);
    }

    private static byte[] BuildData(long blockNumber, byte[] data, int length)
    {
        var packet = new byte[4 + length];
        WriteInt16(packet, 0, OpData);
        WriteInt16(packet, 2, (short)(ushort)(blockNumber & 0xFFFF));
        Buffer.BlockCopy(data, 0, packet, 4, length);
        return packet;
    }

    private static byte[] BuildError(short errorCode, string message)
    {
        var msgBytes = Encoding.ASCII.GetBytes(message);
        var packet = new byte[4 + msgBytes.Length + 1];
        WriteInt16(packet, 0, OpError);
        WriteInt16(packet, 2, errorCode);
        Buffer.BlockCopy(msgBytes, 0, packet, 4, msgBytes.Length);
        packet[^1] = 0;
        return packet;
    }

    private static byte[] BuildOack(Dictionary<string, string> options)
    {
        using var ms = new MemoryStream();
        ms.WriteByte(0);
        ms.WriteByte((byte)OpOack);
        foreach (var kvp in options)
        {
            WriteAsciiZ(ms, kvp.Key);
            WriteAsciiZ(ms, kvp.Value);
        }
        return ms.ToArray();
    }

    private static void WriteAsciiZ(Stream stream, string value)
    {
        var bytes = Encoding.ASCII.GetBytes(value);
        stream.Write(bytes, 0, bytes.Length);
        stream.WriteByte(0);
    }

    private static bool TryParseRrq(byte[] request, out string fileName, out string mode,
        out Dictionary<string, string> options, out string? error)
    {
        fileName = string.Empty;
        mode = string.Empty;
        options = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        error = null;

        var fields = new List<string>();
        int pos = 2;
        var current = new StringBuilder();
        while (pos < request.Length)
        {
            byte b = request[pos++];
            if (b == 0)
            {
                fields.Add(current.ToString());
                current.Clear();
            }
            else
            {
                current.Append((char)b);
            }
        }

        if (fields.Count < 2)
        {
            error = "Request missing filename/mode.";
            return false;
        }

        fileName = fields[0];
        mode = fields[1];

        for (int i = 2; i + 1 < fields.Count; i += 2)
        {
            options[fields[i]] = fields[i + 1];
        }

        return true;
    }

    /// <summary>Resolves a client-supplied relative path against the TFTP root and rejects any escape attempt.</summary>
    private string ResolveSafePath(string requestedFileName)
    {
        string normalized = requestedFileName.Replace('\\', '/').TrimStart('/');
        string combined = Path.GetFullPath(Path.Combine(_rootPath, normalized));
        string rootWithSeparator = _rootPath.EndsWith(Path.DirectorySeparatorChar)
            ? _rootPath
            : _rootPath + Path.DirectorySeparatorChar;

        if (!combined.StartsWith(rootWithSeparator, StringComparison.OrdinalIgnoreCase) &&
            !string.Equals(combined, _rootPath, StringComparison.OrdinalIgnoreCase))
        {
            throw new UnauthorizedAccessException("Path escapes the TFTP root.");
        }
        return combined;
    }

    private static short ReadInt16(byte[] buffer, int offset) =>
        (short)((buffer[offset] << 8) | buffer[offset + 1]);

    private static void WriteInt16(byte[] buffer, int offset, short value)
    {
        buffer[offset] = (byte)((value >> 8) & 0xFF);
        buffer[offset + 1] = (byte)(value & 0xFF);
    }

    private void Log(TftpLogLevel level, string message) =>
        LogMessage?.Invoke(this, new TftpLogEventArgs(level, message));
}
