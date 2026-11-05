using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Text;
using System.Xml.Linq;

namespace Plinth.Windows
{
    internal sealed class DavEntry
    {
        internal string Id;
        internal string ParentId;
        internal string Name;
        internal bool IsDirectory;
        internal long Size;
        internal DateTime ModifiedUtc;
        internal string Etag;
    }

    internal sealed class DavReadStream : IDisposable
    {
        internal readonly Stream Stream;
        internal readonly HttpWebResponse Response;
        internal readonly long EffectiveLength;

        internal DavReadStream(HttpWebResponse response, Stream stream, long length)
        {
            Response = response;
            Stream = stream;
            EffectiveLength = length;
        }

        public void Dispose()
        {
            try { Stream.Dispose(); } catch { }
            try { Response.Dispose(); } catch { }
        }
    }

    internal sealed class DavClient
    {
        private readonly Uri _baseUri;
        private readonly string _auth;

        internal DavClient(string baseUrl, string account, string password)
        {
            if (!baseUrl.EndsWith("/", StringComparison.Ordinal)) baseUrl += "/";
            _baseUri = new Uri(baseUrl, UriKind.Absolute);
            _auth = "Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes(account + ":" + password));
        }

        internal List<DavEntry> List(string id)
        {
            HttpWebRequest request = Request(string.IsNullOrEmpty(id) ? _baseUri : IdUri(id), "PROPFIND");
            request.Headers["Depth"] = "1";
            using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
            using (Stream stream = response.GetResponseStream())
            {
                Check(response, 207);
                List<DavEntry> entries = Parse(stream);
                if (entries.Count > 0) entries.RemoveAt(0);
                return entries;
            }
        }

        internal DavEntry Stat(string id)
        {
            HttpWebRequest request = Request(IdUri(id), "PROPFIND");
            request.Headers["Depth"] = "0";
            try
            {
                using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
                using (Stream stream = response.GetResponseStream())
                {
                    Check(response, 207);
                    List<DavEntry> entries = Parse(stream);
                    return entries.Count == 0 ? null : entries[0];
                }
            }
            catch (WebException ex)
            {
                HttpWebResponse response = ex.Response as HttpWebResponse;
                if (response != null && response.StatusCode == HttpStatusCode.NotFound)
                {
                    response.Dispose();
                    return null;
                }
                throw;
            }
        }

        internal DavEntry CreateDirectory(string parentId, string name)
        {
            HttpWebRequest request = Request(ChildUri(parentId, name), "MKCOL");
            using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
            {
                int code = (int)response.StatusCode;
                if (code < 200 || code >= 300)
                    throw new InvalidOperationException("MKCOL failed: HTTP " + code);
            }
            return FindChild(parentId, name);
        }

        internal DavEntry PutFile(string id, string parentId, string name, string localPath)
        {
            Uri destination = string.IsNullOrEmpty(id) ? ChildUri(parentId, name) : IdUri(id);
            FileInfo file = new FileInfo(localPath);
            HttpWebRequest request = Request(destination, "PUT");
            request.ContentType = "application/octet-stream";
            request.ContentLength = file.Length;
            using (Stream output = request.GetRequestStream())
            using (FileStream input = File.Open(localPath, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete))
            {
                input.CopyTo(output, 1024 * 1024);
            }
            using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
            {
                int code = (int)response.StatusCode;
                if (code < 200 || code >= 300)
                    throw new InvalidOperationException("PUT failed: HTTP " + code);
            }
            if (!string.IsNullOrEmpty(id))
            {
                DavEntry existing = Stat(id);
                if (existing == null) throw new InvalidOperationException("Uploaded item could not be re-read.");
                return existing;
            }
            return FindChild(parentId, name);
        }

        private DavEntry FindChild(string parentId, string name)
        {
            List<DavEntry> entries = List(parentId);
            foreach (DavEntry entry in entries)
                if (string.Equals(entry.Name, name, StringComparison.Ordinal)) return entry;
            throw new InvalidOperationException("Created item was not returned by the bridge.");
        }

        internal DavReadStream OpenRead(string id, long offset, long length)
        {
            HttpWebRequest request = Request(IdUri(id), "GET");
            if (offset > 0 || length >= 0)
            {
                long end = length < 0 ? -1 : checked(offset + length - 1);
                if (end >= offset) request.AddRange(offset, end);
                else if (offset > 0) request.AddRange(offset);
            }

            HttpWebResponse response = (HttpWebResponse)request.GetResponse();
            int code = (int)response.StatusCode;
            if (code != 200 && code != 206)
            {
                response.Dispose();
                throw new InvalidOperationException("GET failed: HTTP " + code);
            }

            Stream stream = response.GetResponseStream();
            if (code == 200 && offset > 0) Skip(stream, offset);
            long effective = length;
            if (effective < 0 && response.ContentLength >= 0)
                effective = Math.Max(0, response.ContentLength - (code == 200 ? offset : 0));
            return new DavReadStream(response, stream, effective);
        }

        internal void Delete(string id)
        {
            HttpWebRequest request = Request(IdUri(id), "DELETE");
            try
            {
                using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
                {
                    int code = (int)response.StatusCode;
                    if (code < 200 || code >= 300)
                        throw new InvalidOperationException("DELETE failed: HTTP " + code);
                }
            }
            catch (WebException ex)
            {
                HttpWebResponse response = ex.Response as HttpWebResponse;
                if (response != null && response.StatusCode == HttpStatusCode.NotFound)
                {
                    response.Dispose();
                    return;
                }
                throw;
            }
        }

        internal void Move(string id, string parentId, string name)
        {
            HttpWebRequest request = Request(IdUri(id), "MOVE");
            request.Headers["Destination"] = ChildUri(parentId, name).AbsoluteUri;
            request.Headers["Overwrite"] = "T";
            using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
            {
                int code = (int)response.StatusCode;
                if (code < 200 || code >= 300)
                    throw new InvalidOperationException("MOVE failed: HTTP " + code);
            }
        }

        private HttpWebRequest Request(Uri uri, string method)
        {
            HttpWebRequest request = (HttpWebRequest)WebRequest.Create(uri);
            request.Method = method;
            request.Headers[HttpRequestHeader.Authorization] = _auth;
            request.Timeout = 60000;
            request.ReadWriteTimeout = 60000;
            request.Proxy = null;
            return request;
        }

        private Uri IdUri(string id)
        {
            return new Uri(_baseUri, ".id/" + Uri.EscapeDataString(id));
        }

        private Uri ChildUri(string parentId, string name)
        {
            string relative = string.IsNullOrEmpty(parentId)
                ? Uri.EscapeDataString(name)
                : ".id/" + Uri.EscapeDataString(parentId) + "/" + Uri.EscapeDataString(name);
            return new Uri(_baseUri, relative);
        }

        private static void Check(HttpWebResponse response, int expected)
        {
            if ((int)response.StatusCode != expected)
                throw new InvalidOperationException("DAV returned HTTP " + (int)response.StatusCode);
        }

        private static void Skip(Stream stream, long bytes)
        {
            byte[] buffer = new byte[65536];
            while (bytes > 0)
            {
                int read = stream.Read(buffer, 0, (int)Math.Min(buffer.Length, bytes));
                if (read <= 0) throw new EndOfStreamException();
                bytes -= read;
            }
        }

        private static List<DavEntry> Parse(Stream stream)
        {
            XDocument document = XDocument.Load(stream);
            List<DavEntry> entries = new List<DavEntry>();
            foreach (XElement response in document.Descendants())
            {
                if (response.Name.LocalName != "response") continue;
                XElement prop = null;
                foreach (XElement node in response.Descendants())
                    if (node.Name.LocalName == "prop") { prop = node; break; }
                if (prop == null) continue;

                string href = Value(response, "href");
                string decoded = Uri.UnescapeDataString(href ?? "").TrimEnd('/');
                int slash = decoded.LastIndexOf('/');
                string name = slash >= 0 ? decoded.Substring(slash + 1) : decoded;
                long size;
                if (!long.TryParse(Value(prop, "getcontentlength"), NumberStyles.Integer,
                    CultureInfo.InvariantCulture, out size)) size = 0;
                DateTime modified;
                if (!DateTime.TryParse(Value(prop, "getlastmodified"), CultureInfo.InvariantCulture,
                    DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out modified))
                    modified = DateTime.UtcNow;

                bool directory = false;
                foreach (XElement node in prop.Descendants())
                    if (node.Name.LocalName == "collection") { directory = true; break; }

                entries.Add(new DavEntry {
                    Id = Value(prop, "fileid") ?? "",
                    ParentId = Value(prop, "parentid") ?? "",
                    Name = name,
                    IsDirectory = directory,
                    Size = size,
                    ModifiedUtc = modified.ToUniversalTime(),
                    Etag = Value(prop, "getetag") ?? ""
                });
            }
            return entries;
        }

        private static string Value(XElement parent, string localName)
        {
            foreach (XElement child in parent.Elements())
                if (child.Name.LocalName == localName) return child.Value;
            return "";
        }
    }
}
