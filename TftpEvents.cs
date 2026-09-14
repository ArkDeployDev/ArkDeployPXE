using System.Net;

namespace PxeTftp;

public enum TftpLogLevel
{
    Info,
    Warning,
    Error
}

public sealed class TftpLogEventArgs : EventArgs
{
    public TftpLogLevel Level { get; }
    public string Message { get; }
    public DateTime TimestampUtc { get; } = DateTime.UtcNow;

    public TftpLogEventArgs(TftpLogLevel level, string message)
    {
        Level = level;
        Message = message;
    }

    public override string ToString() => $"[{TimestampUtc:HH:mm:ss.fff}] [{Level}] {Message}";
}

public sealed class TftpTransferEventArgs : EventArgs
{
    public IPEndPoint Client { get; }
    public string FileName { get; }
    public long BytesSent { get; }
    public TimeSpan Duration { get; }
    public string? ErrorMessage { get; }

    public TftpTransferEventArgs(IPEndPoint client, string fileName, long bytesSent, TimeSpan duration, string? errorMessage = null)
    {
        Client = client;
        FileName = fileName;
        BytesSent = bytesSent;
        Duration = duration;
        ErrorMessage = errorMessage;
    }
}
