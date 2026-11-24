# 部署

纯静态,零构建:`web/` 目录即最终产物,放到任何静态托管(Caddy/Nginx/GitHub Pages/Cloudflare Pages)即可。

```
rsync -avz --delete web/ <你的服务器>:/var/www/pervio/
```

HTTPS、域名、CDN 按你的托管商文档来;本仓库不含任何服务器信息。
