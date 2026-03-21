module downloader;

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
    SiteDownloader handles downloading a website recursively and rewriting links.
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

class SiteDownloader
{
    string rootUrl;
    string outputDir;
    string domain;
    bool[string] visitedUrls;
    bool downloadSocial = false;
    string cookies;
    /// When true, only the start URL is fetched as HTML; same-site links are rewritten to absolute URLs.
    bool singlePage = false;
    /// If non-empty, after processing the DOM, replace body content with the first match (CSS selector).
    string cssScope;

    this(string rootUrl, string outputDir, bool downloadSocial = false, string cookies = "",
            bool singlePage = false, string cssScope = "")
    {
        this.rootUrl = rootUrl;
        this.outputDir = outputDir;
        this.downloadSocial = downloadSocial;
        this.cookies = cookies;
        this.singlePage = singlePage;
        this.cssScope = cssScope;
        auto u = URI(rootUrl);
        this.domain = getApexDomain(u.host);
    }

    private string getApexDomain(string host)
    {
        auto parts = host.split(".");
        if (parts.length >= 2)
        {
            if (parts.length > 2 && parts[0] == "www")
                return parts[1 .. $].join(".");
            return host;
        }
        return host;
    }

    void download(int maxDepth = 3)
    {
        // Explicitly try to download favicon.ico from the root
        try
        {
            auto u = URI(rootUrl);
            string favUrl = u.scheme ~ "://" ~ u.host ~ "/favicon.ico";
            downloadAsset(favUrl);
        }
        catch (Exception)
        {
        }

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

        writeln("Downloading: ", url);

        try
        {
            auto req = Request();
            req.verbosity = 0;
            req.sslSetVerifyPeer(false);
            string[string] headers = [
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
            ];
            if (!cookies.empty)
                headers["Cookie"] = cookies;
            req.addHeaders(headers);
            auto rs = req.get(url);

            string finalUrl = rs.finalURI.uri;
            if (finalUrl != url)
                visitedUrls[finalUrl] = true;

            string contentType = rs.responseHeaders.get("Content-Type", "").toLower();
            string localPath = urlToLocalPath(finalUrl, contentType);
            string fullPath = buildPath(outputDir, localPath);
            mkdirRecurse(dirName(fullPath));

            if (contentType.canFind("application/vnd.apple.mpegurl")
                    || contentType.canFind("application/dash+xml")
                    || finalUrl.canFind(".m3u8") || finalUrl.canFind(".mpd"))
            {
                writeln("Skipping streaming media split tech: ", finalUrl);
                return;
            }

            if (contentType.canFind("text/html") || contentType.empty)
            {
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
                                    if (singlePage || currentDepth >= maxDepth)
                                    {
                                        element.setAttribute(tag.attr, absoluteTarget);
                                    }
                                    else
                                    {
                                        crawl(absoluteTarget, currentDepth + 1, maxDepth);
                                        string localTarget = urlToLocalPath(absoluteTarget, "");
                                        element.setAttribute(tag.attr,
                                                getRelativePath(localPath, localTarget));
                                    }
                                }
                                else
                                {
                                    downloadAsset(absoluteTarget);
                                    string localTarget = urlToLocalPath(absoluteTarget,
                                            "application/octet-stream");
                                    element.setAttribute(tag.attr,
                                            getRelativePath(localPath, localTarget));
                                }
                            }
                            else if (targetUrl.startsWith("//"))
                            {
                                element.setAttribute(tag.attr, "https:" ~ targetUrl);
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

                    // Process script tags
                    foreach (element; document.querySelectorAll("script"))
                    {
                        string js = element.innerText;
                        if (js.empty)
                            js = element.innerHTML;
                        if (!js.empty)
                        {
                            string revised = js.replace("'//cdn", "'https://cdn")
                                .replace("\"//cdn", "\"https://cdn")
                                .replace("'//www.weebly.com", "'https://www.weebly.com")
                                .replace("\"//www.weebly.com",
                                        "\"https://www.weebly.com").replace("'//marketplace.editmysite.com",
                                    "'https://marketplace.editmysite.com")
                                .replace("\"//marketplace.editmysite.com",
                                        "\"https://marketplace.editmysite.com");

                            if (revised.canFind("wSlideshow.render"))
                            {
                                auto imgRegex = regex(`"url":"([^"]+)"`);
                                revised = replaceAll!((m) {
                                    string imgRel = m[1];
                                    string imgFull = resolveUrl(finalUrl, "/uploads/" ~ imgRel);
                                    downloadAsset(imgFull);

                                    if (imgFull.endsWith(".jpg")
                                        || imgFull.endsWith(".png") || imgFull.endsWith(".jpeg"))
                                    {
                                        auto dotIdx = imgFull.lastIndexOf(".");
                                        if (dotIdx > 0)
                                        {
                                            string imgOrig = imgFull[0 .. dotIdx]
                                                ~ "_orig" ~ imgFull[dotIdx .. $];
                                            downloadAsset(imgOrig);
                                        }
                                    }

                                    string localTarget = urlToLocalPath(imgFull, "image/jpeg");
                                    string relPath = getRelativePath(localPath, localTarget);
                                    return `"url":"` ~ relPath ~ `"`;
                                })(revised, imgRegex);
                            }

                            // CRITICAL: Fix absolute paths in JS that prepends /
                            revised = revised.replace("\"/uploads/\"", "\"uploads/\"").replace("'/uploads/'",
                                    "'uploads/'").replace(":/uploads/", ":uploads/");

                            if (revised != js)
                                element.innerText = revised;
                        }
                    }

                    // Favicon Fix
                    auto head = document.querySelector("head");
                    if (head)
                    {
                        Element existingFav;
                        foreach (link; head.querySelectorAll("link[rel*='icon']"))
                        {
                            existingFav = link;
                            break;
                        }
                        string favLocal = urlToLocalPath(resolveUrl(rootUrl, "/favicon.ico"), "");
                        string relFavPath = getRelativePath(localPath, favLocal);
                        if (existingFav)
                        {
                            existingFav.setAttribute("href", relFavPath);
                        }
                        else
                        {
                            auto favLink = document.createElement("link");
                            favLink.setAttribute("rel", "shortcut icon");
                            favLink.setAttribute("href", relFavPath);
                            head.appendChild(favLink);
                        }
                    }

                    // Global protocol fixer
                    foreach (tag; [
                        "img", "script", "link", "a", "iframe", "video", "audio",
                        "source"
                    ])
                    {
                        foreach (el; document.querySelectorAll(tag))
                        {
                            string attr = (tag == "a" || tag == "link") ? "href" : "src";
                            if (el.hasAttribute(attr))
                            {
                                string val = el.getAttribute(attr);
                                if (val.startsWith("//"))
                                    el.setAttribute(attr, "https:" ~ val);
                            }
                        }
                    }

                    applyCssScope(document);

                    std.file.write(fullPath, document.toString());
                    return;
                }
            }

            if (contentType.canFind("text/css") || finalUrl.toLower().canFind(".css"))
            {
                string css = cast(string) rs.responseBody.data.idup;
                css = processCssUrls(css, finalUrl, localPath);
                std.file.write(fullPath, css);
                return;
            }

            if (contentType.canFind("javascript") || finalUrl.toLower()
                    .canFind(".js") || finalUrl.toLower().canFind(".mjs"))
            {
                string js = cast(string) rs.responseBody.data.idup;
                string revised = js.replace("\"//", "\"https://").replace("'//", "'https://").replace("\"/uploads/\"+",
                        "\"\"+").replace("'/uploads/'+", "''+").replace("\"/uploads/\"",
                        "\"\"").replace("'/uploads/'", "''");
                std.file.write(fullPath, revised);
                return;
            }

            std.file.write(fullPath, rs.responseBody.data);
        }
        catch (Exception e)
        {
            writeln("Error downloading ", url, ": ", e.msg);
        }
    }

    private void applyCssScope(Document document)
    {
        if (cssScope.empty)
            return;
        auto scopeEl = document.querySelector(cssScope);
        if (scopeEl is null)
        {
            writeln("Warning: --css-scope matched no elements: ", cssScope);
            return;
        }
        auto body = document.querySelector("body");
        if (body is null)
            return;
        body.innerHTML = scopeEl.outerHTML;
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

        bool isAsset = url.toLower().canFind(".jpg") || url.toLower()
            .canFind(".jpeg") || url.toLower().canFind(".png") || url.toLower()
            .canFind(".gif") || url.toLower().canFind(".webp") || url.toLower()
            .canFind(".ico") || url.toLower().canFind(".cur") || url.toLower()
            .canFind(".woff") || url.toLower().canFind(".woff2") || url.toLower()
            .canFind(".ttf") || url.toLower().canFind(".eot") || url.toLower()
            .canFind(".svg") || url.toLower().canFind(".js") || url.toLower()
            .canFind(".mjs") || url.toLower().canFind(".mp4") || url.toLower()
            .canFind(".webm") || url.toLower().canFind(".pdf") || url.toLower()
            .canFind("favicon") || url.toLower().canFind("apple-touch-icon");

        if (isAsset)
        {
            visitedUrls[url] = true;
            mkdirRecurse(dirName(fullPath));
            try
            {
                writeln("Downloading Asset: ", url);
                auto client = HTTP();
                client.handle.set(CurlOption.followlocation, 1);
                client.handle.set(CurlOption.ssl_verifypeer, 0);
                client.setUserAgent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36");
                if (!cookies.empty)
                    client.handle.set(CurlOption.cookie, cookies);
                std.net.curl.download(url.startsWith("//") ? "https:" ~ url : url, fullPath, client);
            }
            catch (Exception e)
            {
                writeln("Failed to download asset ", url, ": ", e.msg);
            }
        }
        else
        {
            crawl(url, 999, 0);
        }
    }

    private string processCssUrls(string css, string baseUrl, string localPath)
    {
        auto r = regex(`url\(\s*(['"]?|&quot;|&#39;)?([^'"\)]*)\1\s*\)`);
        return replaceAll!((m) {
            string targetUrl = std.string.strip(m[2]);
            if (targetUrl.empty || targetUrl.startsWith("data:"))
                return m.hit;
            string absoluteTarget = resolveUrl(baseUrl, targetUrl);
            if (shouldDownload(absoluteTarget, false))
            {
                downloadAsset(absoluteTarget);
                string localTarget = urlToLocalPath(absoluteTarget, "application/octet-stream");
                string relPath = getRelativePath(localPath, localTarget);
                return "url('" ~ relPath ~ "')";
            }
            return m.hit;
        })(css, r);
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

        string basePath = u.path;
        auto qIdx = basePath.indexOf('?');
        if (qIdx != -1)
            basePath = basePath[0 .. qIdx];

        if (relative.startsWith("/"))
            return u.scheme ~ "://" ~ u.host ~ relative;

        if (!basePath.endsWith("/"))
        {
            auto lastSlash = basePath.lastIndexOf("/");
            if (lastSlash != -1)
                basePath = basePath[0 .. lastSlash + 1];
            else
                basePath = "/";
        }

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
                clean ~= p;
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
            string host = u.host.toLower();

            if (!downloadSocial && !isLink && (host.canFind("twitter.com")
                    || host.canFind("x.com") || host.canFind("t.co")
                    || host.canFind("twimg.com") || host.canFind("twitter.jp")))
                return false;

            string targetDomain = getApexDomain(u.host);
            if (isLink)
                return targetDomain == this.domain;
            return true;
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
            auto absFrom = absolutePath(buildNormalizedPath(from));
            auto absTo = absolutePath(buildNormalizedPath(to));
            auto fromDir = dirName(absFrom);
            string rel = relativePath(absTo, fromDir);
            return rel.replace("\\", "/");
        }
        catch (Exception e)
        {
            return to;
        }
    }
}
