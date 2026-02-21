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

import requests;
import arsd.dom;

/**
    SiteArchiver handles downloading a website recursively and rewriting links.
*/
struct AssetTag {
    string name;
    string attr;
}

static immutable AssetTag[] assetTags = [
    {"a", "href"}, {"link", "href"}, {"img", "src"},
    {"script", "src"}, {"video", "src"}, {"audio", "src"},
    {"source", "src"}, {"track", "src"}, {"iframe", "src"}
];

class SiteArchiver {
    string rootUrl;
    string outputDir;
    string domain;
    bool[string] visitedUrls;

    this(string rootUrl, string outputDir) {
        this.rootUrl = rootUrl;
        this.outputDir = outputDir;
        auto u = URI(rootUrl);
        this.domain = getApexDomain(u.host);
    }

    private string getApexDomain(string host) {
        auto parts = host.split(".");
        if (parts.length >= 2) {
            // Very simple apex extraction: "www.google.com" -> "google.com"
            // "sub.google.co.uk" -> "google.co.uk" (heuristic)
            if (parts.length > 2 && parts[0] == "www") return parts[1..$].join(".");
            return host;
        }
        return host;
    }

    void archive(int maxDepth = 3) {
        crawl(rootUrl, 0, maxDepth);
    }

    private void crawl(string url, int currentDepth, int maxDepth) {
        if (url.empty || url.startsWith("mailto:") || url.startsWith("tel:") || url.startsWith("javascript:")) return;
        if (url in visitedUrls) return;
        visitedUrls[url] = true;

        writeln("Archiving: ", url);

        try {
            auto req = Request();
            req.verbosity = 0;
            req.sslSetVerifyPeer(false);
            auto rs = req.get(url);
            
            string finalUrl = rs.finalURI.uri;
            if (finalUrl != url) visitedUrls[finalUrl] = true;

            string contentType = rs.responseHeaders.get("Content-Type", "").toLower();
            string localPath = urlToLocalPath(finalUrl);
            string fullPath = buildPath(outputDir, localPath);
            mkdirRecurse(dirName(fullPath));

            // Skip problematic media technology (HLS/DASH)
            if (contentType.canFind("application/vnd.apple.mpegurl") || 
                contentType.canFind("application/dash+xml") ||
                finalUrl.canFind(".m3u8") || finalUrl.canFind(".mpd")) {
                writeln("Skipping streaming media split tech: ", finalUrl);
                return;
            }

            if (contentType.canFind("text/html") || contentType.empty) {
                // Heuristic: check if body looks like HTML if no content-type
                string html = cast(string)rs.responseBody.data.idup;
                if (std.string.strip(html).startsWith("<") || contentType.canFind("text/html")) {
                    auto document = new Document(html);

                    foreach(tag; assetTags) {
                        foreach(element; document.querySelectorAll(tag.name)) {
                            if (!element.hasAttribute(tag.attr)) continue;

                            string targetUrl = element.getAttribute(tag.attr);
                            string absoluteTarget = resolveUrl(finalUrl, targetUrl);
                            bool isLink = (tag.name == "a");

                            if (shouldDownload(absoluteTarget, isLink)) {
                                if (isLink) {
                                    if (currentDepth < maxDepth) {
                                        crawl(absoluteTarget, currentDepth + 1, maxDepth);
                                    }
                                } else {
                                    downloadAsset(absoluteTarget);
                                }

                                string localTarget = urlToLocalPath(absoluteTarget);
                                element.setAttribute(tag.attr, getRelativePath(localPath, localTarget));
                            }
                        }
                    }
                    std.file.write(fullPath, document.toString());
                    return;
                }
            }
            
            // Non-HTML content
            std.file.write(fullPath, rs.responseBody.data);
            
        } catch (Exception e) {
            writeln("Error archiving ", url, ": ", e.msg);
        }
    }

    private void downloadAsset(string url) {
        if (url in visitedUrls) return;
        crawl(url, 999, 0); 
    }

    private string resolveUrl(string base, string relative) {
        if (relative.empty || relative.startsWith("#")) return base;
        if (relative.startsWith("http")) return relative;
        
        auto u = URI(base);
        if (relative.startsWith("//")) return u.scheme ~ ":" ~ relative;
        if (relative.startsWith("/")) {
            return u.scheme ~ "://" ~ u.host ~ relative;
        }
        
        string basePath = u.path;
        if (!basePath.endsWith("/")) {
            auto lastSlash = basePath.lastIndexOf("/");
            if (lastSlash != -1) basePath = basePath[0..lastSlash+1];
            else basePath = "/";
        }
        
        return u.scheme ~ "://" ~ u.host ~ basePath ~ relative;
    }

    private bool shouldDownload(string url, bool isLink) {
        auto u = URI(url);
        string targetDomain = getApexDomain(u.host);
        
        // Always follow links to the same domain
        if (isLink) {
            return targetDomain == this.domain || targetDomain.endsWith("." ~ this.domain);
        }
        
        // Always download assets (images/js/css) regardless of domain
        return true; 
    }

    private string urlToLocalPath(string url) {
        auto u = URI(url);
        string hostname = u.host;
        string path = u.path;
        
        import std.algorithm.searching : countUntil;
        auto hashIdx = path.countUntil("#");
        if (hashIdx != -1) path = path[0..hashIdx];
        
        if (path.startsWith("/")) path = path[1..$];
        if (path.empty) path = "index.html";
        else if (path.endsWith("/")) path ~= "index.html";
        
        // Sanitize
        import std.string : tr;
        path = path.tr(`<>:"|?*#`, `________`);
        
        // Force extensions for common types if missing
        if (!path.canFind(".")) path ~= ".html";

        if (getApexDomain(hostname) == this.domain) return path;
        return buildPath("external", hostname, path);
    }

    private string getRelativePath(string from, string to) {
        try {
            auto fromDir = dirName(from);
            string rel = to;
            if (fromDir != ".") rel = relativePath(to, fromDir);
            return rel.replace("\\", "/");
        } catch (Exception e) {
            return to.replace("\\", "/");
        }
    }
}
