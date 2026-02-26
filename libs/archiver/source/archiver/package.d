module archiver;

import std.stdio;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.uri;
import std.net.curl;
import std.conv;
import std.typecons;
import std.string;
import std.regex;
import requests;
import arsd.dom;

/**
    SiteArchiver handles downloading a website recursively and rewriting links.
*/
struct AssetTag
{
    string name;
    string attr;
}

static immutable AssetTag[] assetTags = [
    {"a", "href"}, {"link", "href"}, {"img", "src"}, {"script", "src"},
    {"video", "src"}, {"audio", "src"}, {"source", "src"}, {"track", "src"},
    {"iframe", "src"}
];

class SiteArchiver
{
    string rootUrl;
    string outputDir;
    string domain;
    bool[string] visitedUrls;

    this(string rootUrl, string outputDir)
    {
        this.rootUrl = rootUrl;
        this.outputDir = outputDir;
        auto u = URI(rootUrl);
        this.domain = getApexDomain(u.host);
    }

    private string getApexDomain(string host)
    {
        auto parts = host.split(".");
        if (parts.length >= 2)
        {
            // Very simple apex extraction: "www.google.com" -> "google.com"
            // "sub.google.co.uk" -> "google.co.uk" (heuristic)
            if (parts.length > 2 && parts[0] == "www")
                return parts[1 .. $].join(".");
            return host;
        }
        return host;
    }

    void archive(int maxDepth = 3)
    {
        crawl(rootUrl, 0, maxDepth);
    }

    private void crawl(string url, int currentDepth, int maxDepth)
    {
        if (url.empty || url.startsWith("mailto:") || url.startsWith("tel:")
                || url.startsWith("javascript:"))
            return;
        if (url in visitedUrls && currentDepth > 0)
            return;
        visitedUrls[url] = true;

        writeln("Archiving: ", url);

        try
        {
            auto req = Request();
            req.verbosity = 0;
            req.sslSetVerifyPeer(false);
            // Set User-Agent to avoid blocks from CDNs
            req.addHeaders([
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
            ]);
            auto rs = req.get(url);

            string finalUrl = rs.finalURI.uri;
            if (finalUrl != url)
                visitedUrls[finalUrl] = true;

            string contentType = rs.responseHeaders.get("Content-Type", "").toLower();
            string localPath = urlToLocalPath(finalUrl, contentType);
            string fullPath = buildPath(outputDir, localPath);
            mkdirRecurse(dirName(fullPath));

            // Skip problematic media technology (HLS/DASH)
            if (contentType.canFind("application/vnd.apple.mpegurl")
                    || contentType.canFind("application/dash+xml")
                    || finalUrl.canFind(".m3u8") || finalUrl.canFind(".mpd"))
            {
                writeln("Skipping streaming media split tech: ", finalUrl);
                return;
            }

            if (contentType.canFind("text/html") || contentType.empty)
            {
                // Heuristic: check if body looks like HTML if no content-type
                string html = cast(string) rs.responseBody.data.idup;
                if (std.string.strip(html).startsWith("<") || contentType.canFind("text/html"))
                {
                    auto document = new Document(html);

                    foreach (tag; assetTags)
                    {
                        foreach (element; document.querySelectorAll(tag.name))
                        {
                            if (!element.hasAttribute(tag.attr))
                                continue;

                            string targetUrl = element.getAttribute(tag.attr);
                            string absoluteTarget = resolveUrl(finalUrl, targetUrl);
                            bool isLink = (tag.name == "a");

                            if (shouldDownload(absoluteTarget, isLink))
                            {
                                if (isLink)
                                {
                                    if (currentDepth < maxDepth)
                                    {
                                        crawl(absoluteTarget, currentDepth + 1, maxDepth);
                                    }
                                }
                                else
                                {
                                    downloadAsset(absoluteTarget);
                                }

                                string localTarget = urlToLocalPath(absoluteTarget, "");
                                element.setAttribute(tag.attr,
                                        getRelativePath(localPath, localTarget));
                            }
                        }
                    }

                    // Process inline styles
                    foreach (element; document.querySelectorAll("[style]"))
                    {
                        string style = element.getAttribute("style");
                        if (!style.empty)
                        {
                            string revised = processCssUrls(style, finalUrl, localPath);
                            if (revised != style)
                                element.setAttribute("style", revised);
                        }
                    }

                    // Process style tags
                    foreach (element; document.querySelectorAll("style"))
                    {
                        string css = element.innerText;
                        if (css.empty)
                            css = element.innerHTML;

                        if (!css.empty)
                        {
                            string revised = processCssUrls(css, finalUrl, localPath);
                            if (revised != css)
                                element.innerText = revised;
                        }
                    }

                    // Process script tags to fix protocol-relative URLs (//)
                    foreach (element; document.querySelectorAll("script"))
                    {
                        string js = element.innerText;
                        if (js.empty)
                            js = element.innerHTML;
                        if (!js.empty)
                        {
                            // Fix common Weebly protocol-relative URLs
                            // Use string replacement for common CDN patterns
                            string revised = js.replace("'//cdn", "'https://cdn")
                                .replace("\"//cdn", "\"https://cdn")
                                .replace("'//www.weebly.com", "'https://www.weebly.com")
                                .replace("\"//www.weebly.com",
                                        "\"https://www.weebly.com").replace("'//marketplace.editmysite.com",
                                    "'https://marketplace.editmysite.com")
                                .replace("\"//marketplace.editmysite.com",
                                        "\"https://marketplace.editmysite.com");

                            // Weebly Slideshow Support: Find images in JSON blocks
                            if (js.canFind("wSlideshow.render"))
                            {
                                // Regex to find "url":"..." in the JSON images array
                                auto imgRegex = regex(`"url":"([^"]+)"`);
                                foreach (m; js.matchAll(imgRegex))
                                {
                                    string imgRel = m[1];
                                    // Weebly images in slideshows are relative to /uploads/
                                    string imgFull = resolveUrl(finalUrl, "/uploads/" ~ imgRel);
                                    downloadAsset(imgFull);

                                    // Also try the _orig version which Weebly often uses for higher quality
                                    if (imgFull.endsWith(".jpg") || imgFull.endsWith(".png"))
                                    {
                                        auto dotIdx = imgFull.lastIndexOf(".");
                                        string imgOrig = imgFull[0 .. dotIdx]
                                            ~ "_orig" ~ imgFull[dotIdx .. $];
                                        downloadAsset(imgOrig);
                                    }
                                }
                            }

                            if (revised != js)
                            {
                                // IMPORTANT: Use innerText/textContent for scripts to avoid arsd.dom 
                                // parsing JS string contents as HTML nodes (which mangles the DOM)
                                element.innerText = revised;
                            }
                        }
                    }

                    std.file.write(fullPath, document.toString());
                    return;
                }
            }

            bool isCss = contentType.canFind("text/css") || finalUrl.toLower().canFind(".css");
            if (isCss)
            {
                string css = cast(string) rs.responseBody.data.idup;
                css = processCssUrls(css, finalUrl, localPath);
                std.file.write(fullPath, css);
                return;
            }

            // Non-HTML content
            std.file.write(fullPath, rs.responseBody.data);

        }
        catch (Exception e)
        {
            writeln("Error archiving ", url, ": ", e.msg);
        }
    }

    private void downloadAsset(string url)
    {
        if (url.empty || url.startsWith("mailto:") || url.startsWith("tel:")
                || url.startsWith("javascript:"))
            return;
        if (url in visitedUrls)
            return;

        string localPath = urlToLocalPath(url, "");
        string fullPath = buildPath(outputDir, localPath);

        // For assets like images and fonts, just download them
        bool isAsset = url.toLower().canFind(".jpg") || url.toLower()
            .canFind(".jpeg") || url.toLower().canFind(".png") || url.toLower()
            .canFind(".gif") || url.toLower().canFind(".woff") || url.toLower()
            .canFind(".woff2") || url.toLower().canFind(".ttf") || url.toLower()
            .canFind(".eot") || url.toLower().canFind(".svg") || url.toLower().canFind(".js");

        if (isAsset)
        {
            visitedUrls[url] = true;
            mkdirRecurse(dirName(fullPath));
            try
            {
                writeln("Archiving Asset: ", url);
                auto client = HTTP();
                client.handle.set(CurlOption.followlocation, 1);
                client.setUserAgent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36");
                std.net.curl.download(url.startsWith("//") ? "https:" ~ url : url, fullPath, client);
            }
            catch (Exception e)
            {
                writeln("Failed to download asset ", url, ": ", e.msg);
            }
        }
        else
        {
            // Probably HTML or CSS, use crawl to process it
            crawl(url, 999, 0);
        }
    }

    private string processCssUrls(string css, string baseUrl, string localPath)
    {
        writeln("Processing CSS (", css.length, " bytes) from ", baseUrl);
        // Handle url(...) with any quotes or no quotes, and handle html entities
        // Matches url( ... ) with optional quotes or entities
        auto r = regex(`url\(\s*(['"]?|&quot;|&#39;)?([^'"\)]*)\1\s*\)`);
        int matchCount = 0;
        string result = replaceAll!((m) {
            matchCount++;
            string targetUrl = std.string.strip(m[2]);
            if (targetUrl.empty || targetUrl.startsWith("data:"))
                return m.hit;

            string absoluteTarget = resolveUrl(baseUrl, targetUrl);
            if (shouldDownload(absoluteTarget, false))
            {
                downloadAsset(absoluteTarget);
                string localTarget = urlToLocalPath(absoluteTarget, "");
                string relPath = getRelativePath(localPath, localTarget);
                // writeln("Rewriting CSS URL: ", targetUrl, " -> ", relPath, " (in ", localPath, ")");
                return "url('" ~ relPath ~ "')";
            }
            return m.hit;
        })(css, r);
        writeln("Finished processing CSS from ", baseUrl, ": found ",
                matchCount, " url() references.");
        return result;
    }

    private string resolveUrl(string base, string relative)
    {
        if (relative.empty || relative.startsWith("#"))
            return base;
        if (relative.startsWith("http"))
            return relative;

        auto u = URI(base);
        if (relative.startsWith("//"))
            return u.scheme ~ ":" ~ relative;
        if (relative.startsWith("/"))
        {
            // Strip query string from base path for resolution
            string basePath = u.path;
            auto qIdx = basePath.indexOf('?');
            if (qIdx != -1)
                basePath = basePath[0 .. qIdx];
            return u.scheme ~ "://" ~ u.host ~ relative;
        }

        string basePath = u.path;
        // Strip query string from base path for resolution
        auto qIdx = basePath.indexOf('?');
        if (qIdx != -1)
            basePath = basePath[0 .. qIdx];

        if (!basePath.endsWith("/"))
        {
            auto lastSlash = basePath.lastIndexOf("/");
            if (lastSlash != -1)
                basePath = basePath[0 .. lastSlash + 1];
            else
                basePath = "/";
        }

        // Manual normalization of path
        import std.array : split, join;
        import std.algorithm.iteration : filter;

        string combined = basePath ~ relative;
        auto parts = combined.split("/");
        string[] clean;
        foreach (p; parts)
        {
            if (p == "." || (p.empty && clean.length > 0))
                continue;
            if (p == "..")
            {
                if (clean.length > 0 && clean[$ - 1] != "..")
                    clean = clean[0 .. $ - 1];
                else
                    clean ~= "..";
            }
            else
            {
                clean ~= p;
            }
        }
        string norm = clean.join("/");
        if (!norm.startsWith("/"))
            norm = "/" ~ norm;

        return u.scheme ~ "://" ~ u.host ~ norm;
    }

    private bool shouldDownload(string url, bool isLink)
    {
        try
        {
            auto u = URI(url);
            string targetDomain = getApexDomain(u.host);

            if (isLink)
            {
                return targetDomain == this.domain;
            }

            return true; // Always download assets
        }
        catch (Exception)
        {
            return false;
        }
    }

    private string urlToLocalPath(string url, string contentType)
    {
        auto u = URI(url);
        string hostname = u.host;
        string path = u.path;

        // Strip query and fragment for the filename
        foreach (sep; ['?', '#'])
        {
            auto idx = path.indexOf(sep);
            if (idx != -1)
                path = path[0 .. idx];
        }

        if (path.startsWith("/"))
            path = path[1 .. $];
        if (path.empty)
            path = "index.html";
        else if (path.endsWith("/"))
            path ~= "index.html";

        // Sanitize for Windows
        import std.string : tr;

        path = path.tr(`<>:"|?*#`, `________`);

        if (path.canFind("index.html") || contentType.canFind("text/html")
                || path.empty || (!path.canFind(".") && (contentType.empty
                    || contentType.canFind("text/html"))))
        {
            if (!path.canFind("."))
                path ~= ".html";
        }

        if (getApexDomain(hostname) == this.domain)
            return path;
        return buildPath("external", hostname, path);
    }

    private string getRelativePath(string from, string to)
    {
        try
        {
            import std.path : relativePath, dirName, buildNormalizedPath, absolutePath;

            // Use absolute paths to ensure relativePath works correctly on Windows
            auto absFrom = absolutePath(buildNormalizedPath(from));
            auto absTo = absolutePath(buildNormalizedPath(to));
            auto fromDir = dirName(absFrom);

            string rel = relativePath(absTo, fromDir);
            return rel.replace("\\", "/");
        }
        catch (Exception e)
        {
            writeln("Relative path error: ", e.msg);
            return to;
        }
    }
}
