# Detailed Migration Blueprint: WordPress to Shopify Subdomain

## 1. The Scenario

- **Main Site (WordPress):** `<company-domain>.us` (Running on ECS)
- **New Store/Courses (Shopify):** `academy.<company-domain>.com`
- **The Problem:** You have 300+ legacy links on the `.us` domain (e.g., `<company-domain>.us/courses/yoga`) that need to automatically point to the new home on the `.com` subdomain.
- **The Constraint:** You only have 0.5 CPU and 1 GB RAM on your ECS task.

---

## 2. The Solution: Nginx Path-Mapping

Instead of a "catch-all" redirect that might break your WordPress site, we use Nginx to look at the specific path requested. If the path matches one of your 300+ migrated pages, Nginx sends the user to the new Shopify subdomain. If not, it lets them stay on WordPress.

**Why this is the "Best Practice":**

1. **Zero SEO Loss:** Using `301 Moved Permanently` tells Google exactly where the new page is, preserving your search rankings.
2. **Credit Preservation:** This logic happens in Nginx memory. It won't trigger "CPU Credit" spikes on your T3 instances like a WordPress PHP plugin would.
3. **Clean Separation:** Your WordPress database stays clean of "Redirect Junk."

---

## 3. Implementation Guide

### Step A: The Redirect Map (`redirects.map`)

Create this file in your Nginx config folder. Notice we only need the path for the old site and the full URL for the new one.

```/bin/bash
# /etc/nginx/conf.d/redirects.map

# Old Path on .us                  # New Destination on .com (Shopify)
/courses/ayurveda-101              https://academy<company-domain>.com/products/ayurveda-101;
/courses/health-coach              https://academy.<company-domain>.com/products/health-coach;
/blog/ayurveda-tips                https://academy.<company-domain>.com/blogs/news/tips;
# ... add all 300 entries here
```

### Step B: The Nginx Logic (`nginx.conf`)

This configuration tells Nginx: "Check the map first. If you find a match, send them to the Academy. If not, show them the WordPress site."

```nginx
# Define the lookup table
map $request_uri $target_shopify_url {
    default       "";
    include       /etc/nginx/conf.d/redirects.map;
}

server {
    listen 80;
    server_name <company-domain>.us;

    # 1. High-Priority Check: Does this path belong to Shopify?
    if ($target_shopify_url != "") {
        return 301 $target_shopify_url;
    }

    # 2. Regular Traffic: Send to WordPress Container
    location / {
        proxy_pass http://wordpress_backend; # Your ECS Service Name
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

---

## 4. Operational Cost & Performance

| Feature | Impact on your 0.5 CPU / 1GB RAM Task |
|---|---|
| **Memory** | Minimal. 300 lines of text use ~128KB of RAM. |
| **CPU** | Ultra-Low. Nginx uses a "Hash Table" to find the redirect, which is the fastest way computer science allows. |
| **Latency** | Zero. The user won't even notice the redirect happening; it's faster than a page load. |

---

## 5. Critical Checklist for Your Transition

1. **DNS Config:** Ensure `academy.<company-domain>.com` is pointed to Shopify (via CNAME) and `<company-domain>.us` is pointed to your AWS Load Balancer (ALB).
2. **SSL/HTTPS:** Since you are redirecting to a different domain, make sure both domains have valid SSL certificates. Cloudflare usually handles this easily.
3. **Wildcard Caution:** Don't do a blanket redirect of `/courses/*` unless every single course is ready on Shopify. Using the map file allows you to migrate one page at a time.
---

> Since you have 300+ URLs, would you like a simple Python script to convert an Excel or CSV file into that `.map` format?