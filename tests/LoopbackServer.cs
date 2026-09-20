using System;
using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

// Offline fixture: binds only to IPv4 loopback and uses an OS-assigned port.
public sealed class ApiTestLoopbackServer : IDisposable
{
    private readonly TcpListener listener = new TcpListener(IPAddress.Loopback, 0);
    private readonly Thread thread;
    private volatile bool stopped;
    public readonly ConcurrentQueue<string> Requests = new ConcurrentQueue<string>();
    public readonly ConcurrentQueue<byte[]> Bodies = new ConcurrentQueue<byte[]>();
    public int Port { get; private set; }

    public ApiTestLoopbackServer()
    {
        listener.Start();
        Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        thread = new Thread(Accept) { IsBackground = true };
        thread.Start();
    }

    private void Accept()
    {
        while (!stopped)
        {
            try { var client = listener.AcceptTcpClient(); Task.Run(() => Handle(client)); }
            catch (SocketException) { if (!stopped) throw; }
        }
    }

    private void Handle(TcpClient client)
    {
        using (client)
        {
            try
            {
                client.ReceiveTimeout = 5000;
                client.SendTimeout = 5000;
                var stream = client.GetStream();
                var headerBytes = new MemoryStream();
                int next;
                while ((next = stream.ReadByte()) >= 0)
                {
                    headerBytes.WriteByte((byte)next);
                    var buffer = headerBytes.GetBuffer();
                    int length = (int)headerBytes.Length;
                    if (length >= 4 && buffer[length - 4] == 13 && buffer[length - 3] == 10 && buffer[length - 2] == 13 && buffer[length - 1] == 10) break;
                    if (length > 65536) throw new IOException("Header limit");
                }
                string headers = Encoding.UTF8.GetString(headerBytes.ToArray());
                int bodyLength = 0;
                foreach (string line in headers.Split(new[] { "\r\n" }, StringSplitOptions.None))
                    if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase)) bodyLength = int.Parse(line.Substring(15).Trim());
                if (headers.IndexOf("Expect: 100-continue", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    byte[] interim = Encoding.ASCII.GetBytes("HTTP/1.1 100 Continue\r\n\r\n");
                    stream.Write(interim, 0, interim.Length);
                }
                if (bodyLength > 12000000) throw new IOException("Body limit");
                var body = new byte[bodyLength];
                int offset = 0;
                while (offset < body.Length) { int read = stream.Read(body, offset, body.Length - offset); if (read == 0) break; offset += read; }
                Requests.Enqueue(headers); Bodies.Enqueue(body);
                string path = headers.Split(' ')[1].Split('?')[0];
                if (path == "/slow") Thread.Sleep(2000);
                int status = path == "/fail" ? 500 : path == "/missing" ? 404 : path == "/redirect" ? 302 : 200;
                byte[] response = Encoding.UTF8.GetBytes("{\"ok\":true,\"Authorization\":\"Bearer RESPONSE-SECRET\",\"refresh_token\":\"RESPONSE-REFRESH\"}");
                if (path == "/echo") response = body;
                if (path == "/large") response = new byte[300000];
                if (path == "/binary") response = new byte[] { 0, 255, 1 };
                if (path == "/unicode") response = Encoding.UTF8.GetBytes("<response><name>\u00c4\u00c5\u00e9</name></response>");
                bool chunked = path == "/chunked";
                if (chunked) response = new byte[4096];
                string responseHeaders = "HTTP/1.1 " + status + " Test\r\nConnection: close\r\nContent-Type: application/json\r\nSet-Cookie: session=COOKIE-SECRET\r\n";
                if (status == 302) responseHeaders += "Location: /echo\r\n";
                if (path == "/unicode") responseHeaders = responseHeaders.Replace("application/json", "text/xml; charset=utf-8") + "X-Display-Name: \u00c4\u00c5\u00e9\r\n";
                responseHeaders += chunked ? "Transfer-Encoding: chunked\r\n\r\n" : "Content-Length: " + response.Length + "\r\n\r\n";
                byte[] prefix = Encoding.UTF8.GetBytes(responseHeaders);
                stream.Write(prefix, 0, prefix.Length);
                if (!headers.StartsWith("HEAD ", StringComparison.Ordinal))
                {
                    if (chunked) { byte[] size = Encoding.ASCII.GetBytes(response.Length.ToString("x") + "\r\n"); stream.Write(size, 0, size.Length); }
                    stream.Write(response, 0, response.Length);
                    if (chunked) { byte[] end = Encoding.ASCII.GetBytes("\r\n0\r\n\r\n"); stream.Write(end, 0, end.Length); }
                }
            }
            catch (IOException) { }
            catch (ObjectDisposedException) { }
        }
    }

    public void Dispose() { stopped = true; listener.Stop(); thread.Join(5000); }
}
