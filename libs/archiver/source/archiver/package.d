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

import requests;
import arsd.dom;

/**
    SiteArchiver handles downloading a website recursively and rewriting links.
*/
class SiteArchiver {
    string rootUrl;
    string outputDir;
    string domain;
    bool[string] visitedUrls;

    this(string rootUrl, string outputDir) {
        this.rootUrl = rootUrl;
        this.outputDir = outputDir;
        // Simple domain extraction
        auto u = parseUri(rootUrl);
        this.domain = u.host;
    }

    void archive(int maxDepth = 3) {
        crawl(rootUrl, 0, maxDepth);
    }

    private void crawl(string url, int currentDepth, int maxDepth) {
        if (currentDepth > maxDepth || url in visitedUrls) return;
        visitedUrls[url] = true;

        writeln("Archiving: ", url);

        try {
            auto rs = getContent(url);
            string contentType = rs.responseHeaders.get("Content-Type", "text/html");

            string localPath = urlToLocalPath(url);
            string fullPath = buildPath(outputDir, localPath);
            mkdirRecurse(dirName(fullPath));

            if (contentType.canFind("text/html")) {
                string html = rs.responseBody.toString();
                auto document = new Document(html);

                // Process links
                foreach(element; document.querySelectorAll("a, link, img, script")) {
                    string attr = "";
                    if (element.tagName == "a" || element.tagName == "link") attr = "href";
                    else if (element.tagName == "img" || element.tagName == "script") attr = "src";

                    if (!attr.empty && element.hasAttribute(attr)) {
                        string targetUrl = element.getAttribute(attr);
                        string absoluteTarget = resolveUrl(url, targetUrl);

                        if (shouldDownload(absoluteTarget)) {
                            // Recursively crawl if it's a link and we have depth
                            if (element.tagName == "a" && currentDepth < maxDepth) {
                                crawl(absoluteTarget, currentDepth + 1, maxDepth);
                            }

                            // Rewrite link to local relative path
                            string localTarget = urlToLocalPath(absoluteTarget);
                            element.setAttribute(attr, getRelativePath(localPath, localTarget));
                        }
                    }
                }

                std.file.write(fullPath, document.toString());
            } else {
                // Non-HTML content (images, css, etc.)
                std.file.write(fullPath, rs.responseBody.data);
            }
        } catch (Exception e) {
            writeln("Error archiving ", url, ": ", e.msg);
        }
    }

    private string resolveUrl(string base, string relative) {
        // Basic URL resolution
        if (relative.startsWith("http")) return relative;
        // This is a simplification; a real implementation should handle more cases
        auto u = parseUri(base);
        if (relative.startsWith("/")) {
            return u.scheme ~ "://" ~ u.host ~ relative;
        }
        return base.dirName ~ "/" ~ relative;
    }

    private bool shouldDownload(string url) {
        auto u = parseUri(url);
        return u.host == this.domain || u.host.endsWith("." ~ this.domain);
    }

    private string urlToLocalPath(string url) {
        auto u = parseUri(url);
        string path = u.path;
        if (path.empty || path == "/") path = "index.html";
        if (path.endsWith("/")) path ~= "index.html";
        if (!path.canFind(".")) path ~= ".html";
        return buildPath(u.host, path);
    }

    private string getRelativePath(string from, string to) {
        // Simplified relative path calculation
        return to; // For now
    }
}

// Minimal URI parser for the example
struct UriParts {
    string scheme;
    string host;
    string path;
}

UriParts parseUri(string uri) {
    // Very simplified parser
    UriParts p;
    auto idx = uri.indexOf("://");
    if (idx != -1) {
        p.scheme = uri[0..idx];
        string rest = uri[idx+3..$];
        auto pIdx = rest.indexOf("/");
        if (pIdx != -1) {
            p.host = rest[0..pIdx];
            p.path = rest[pIdx..$];
        } else {
            p.host = rest;
            p.path = "/";
        }
    }
    return p;
}
