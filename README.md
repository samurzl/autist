# Two-List Todo (iPhone)

A lightweight, mobile-first two-list todo app designed for iPhone-sized screens.

## Install on your iPhone (add to Home Screen)

The app is a static site, so you just need to host the files and open the URL
on your iPhone. Once it loads in Safari, you can add it to your Home Screen.

### 1) Run the app locally

From this repo folder, start a simple local web server:

```bash
python3 -m http.server 8000
```

> If you already use a different static server (Node, nginx, etc.), that works
> too—just make sure it serves `index.html` from this directory.

### 2) Open the app on your iPhone

1. Make sure your iPhone and your computer are on the **same Wi‑Fi network**.
2. Find your computer's local IP address:

   - macOS: `System Settings → Network` (look for the IP address)
   - Windows: `ipconfig` in Command Prompt (look for IPv4 Address)
   - Linux: `ip a` (look for `inet` on your Wi‑Fi interface)

3. On your iPhone, open Safari and go to:

```
http://<YOUR_COMPUTER_IP>:8000
```

### 3) Add to Home Screen

1. In Safari, tap the **Share** button.
2. Scroll and tap **Add to Home Screen**.
3. Name it (e.g., "Two-List Todo") and tap **Add**.

The app will now launch full‑screen from your Home Screen like a native app.

## Optional: Host it online

If you want to install without being on the same Wi‑Fi, host the files on a
static host (GitHub Pages, Netlify, Vercel, etc.) and visit that URL on your
phone, then repeat the **Add to Home Screen** steps.
