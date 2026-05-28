<div dir="rtl">

# PicoTun — تانل رمزنگاری‌شده معکوس

[![Version](https://img.shields.io/badge/version-v2.5.2-blue)](https://github.com/amir6dev/PicoTun/releases)
[![Go](https://img.shields.io/badge/go-1.22-00ADD8)](https://go.dev)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Linux-lightgrey)](#)

> تانل معکوس رمزنگاری‌شده با فریمینگ RFC 6455 WebSocket، دور زدن پیشرفته DPI، لود بالانسینگ چند پورته و پشتیبانی از +۱۲۰ کاربر هم‌زمان

طراحی‌شده برای محیط‌هایی با فیلترینگ عمیق بسته (DPI) — سیستم فیلترینگ ایران، فایروال‌های سازمانی و موارد مشابه.

---

## معماری

</div>

```
[کاربران] → [سرور ایران :2020/:2021] ←smux/WS/AES-256-GCM← [سرور خارج] → [اینترنت]
```

<div dir="rtl">

سرور ایران **منتظر** اتصال تانل از سرور خارج می‌ماند. ترافیک کاربران روی سرور ایران از طریق تانل رمزنگاری‌شده به سرور خارج ارسال شده و از آنجا به اینترنت آزاد می‌رسد. اتصال **از سمت خارج به داخل** برقرار می‌شود — سرور ایران هیچ‌وقت نیازی به reach کردن IP سرور خارج ندارد.

---

## نصب سریع

روی **هر دو سرور** (ایران و خارج) این دستور را اجرا کنید:

</div>

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/amir6dev/PicoTun/main/setup.sh)
```

---

<div dir="rtl">

## ✨ قابلیت‌ها

- **رمزنگاری AES-256-GCM** — تمام ترافیک با احراز هویت رمزنگاری می‌شود
- **فریمینگ RFC 6455 WebSocket** — ترافیک تانل عین یک ارتباط واقعی WebSocket مرورگر به نظر می‌رسد
- **دور زدن DPI** — چرخش دامنه (۱۸ دامنه)، چرخش User-Agent، هدر تصادفی، فرگمنتاسیون TCP
- **مالتی‌پورت** — سرور ایران روی چند پورت همزمان گوش می‌دهد
- **IP بکاپ** — در صورت بلاک شدن IP اصلی خودکار به IP پشتیبان سوئیچ می‌کند
- **بهینه‌سازی کرنل** — فعال‌سازی BBR و تنظیم خودکار TCP Buffer
- **پشتیبانی از +۱۲۰ کاربر هم‌زمان**
- **سرویس Systemd** با ری‌استارت خودکار

---

## 🆕 تغییرات v2.5.2 — فریمینگ WebSocket

مهم‌ترین بهبود ضد-DPI تا به امروز.

### فریمینگ RFC 6455 WebSocket

بعد از handshake ارتقاء HTTP، **تمام داده‌های تانل درون فریم‌های باینری RFC 6455 بسته‌بندی می‌شوند**. قبلاً بعد از handshake از TCP خام استفاده می‌شد — DPI می‌توانست این را تشخیص دهد چون الگوی ترافیک با یک ارتباط WebSocket واقعی مطابقت نداشت.

- **`Sec-WebSocket-Accept` صحیح**: سرور حالا مقدار را با `SHA-1(clientKey + WS magic UUID)` محاسبه و base64 می‌کند. قبلاً یک کلید ثابت از مثال RFC استفاده می‌شد — به‌راحتی قابل شناسایی.
- **ماسک‌گذاری Client**: فریم‌های Client→Server از یک کلید ماسک ۴ بایتی تصادفی برای هر فریم استفاده می‌کنند (الزامی RFC 6455). فریم‌های Server→Client ماسک ندارند. DPI این عدم‌تقارن را از مرورگرهای واقعی انتظار دارد.
- **Opcode 0x02**: تمام فریم‌ها از opcode باینری استفاده می‌کنند، درست مثل انتقال داده WebSocket مرورگرهای واقعی.

### استخر دامنه (۱۸ دامنه)

هر اتصال یک دامنه تصادفی برای هدر `Host` و هدرهای HTTP mimic انتخاب می‌کند:

</div>

```
accounts.google.com    meet.google.com       classroom.google.com
docs.google.com        mail.google.com       drive.google.com
teams.microsoft.com    login.microsoftonline.com  outlook.live.com
onedrive.live.com      cdnjs.cloudflare.com  challenges.cloudflare.com
gateway.icloud.com     api.apple-cloudkit.com
d1.awsstatic.com       api.amazon.com
notify.bugsnag.com     ws.postman-echo.com
```

<div dir="rtl">

### استخر User-Agent به‌روزرسانی‌شده

بین fingerprint‌های مرورگرهای جدید چرخش می‌کند:
- Chrome 124، 125، 126 (Windows + macOS)
- Firefox 125، 127
- Edge 124، 125
- Safari 17.4.1 (macOS + iOS)

### پیش‌فرض‌های Stealth بهبودیافته

| پارامتر | v2.5.1 | v2.5.2 |
|---|---|---|
| حداقل padding | 16 بایت | 32 بایت |
| حداکثر padding | 128 بایت | 256 بایت |
| Conn jitter | 500 میلی‌ثانیه | 800 میلی‌ثانیه |
| فاصله Fake traffic | 30 ثانیه | 20 ثانیه |
| Keepalive jitter | ±2 ثانیه | ±3 ثانیه |

---

## 🆕 تغییرات v2.5.1

- **چرخش دامنه** بین ۱۶ دامنه محبوب (در v2.5.2 به ۱۸ گسترش یافت)
- **چرخش User-Agent** — fingerprint تصادفی مرورگر در هر اتصال
- **هدر تصادفی** — ترتیب هدرهای HTTP به‌صورت تصادفی چیده می‌شود
- **پاسخ تصادفی** — نام سرورهای متنوع (nginx/Apache/cloudflare/gws)
- **Query string تصادفی** — پارامترهای URL یکتا در هر اتصال
- **TCP Fragmentation برای httpmux** — به‌صورت پیش‌فرض فعال
- **۲× بافرهای SMUX/TCP** — max_recv/max_stream از ۱MB به ۲MB، TCP از ۶۴KB به ۱۲۸KB
- **فریم ۸KB** — فریم‌های smux از ۴KB به ۸KB
- **Auto-migrate** — کانفیگ‌های قدیمی خودکار آپگرید می‌شوند

---

## 🆕 تغییرات v2.5

- **لود بالانسر چند پورته** — سرور ایران روی چند پورت همزمان گوش می‌دهد
- **حالت Stealth** — padding تصادفی، burst split، fake traffic، keepalive jitter
- **پشتیبانی از +۱۲۰ کاربر** — محدودیت stream 512، max connections 500
- **Auto-migration کانفیگ** — کانفیگ‌های v2.4/v2.5 خودکار آپگرید
- **چرخش TLS fingerprint تصادفی** — Chrome/Firefox/Edge/Safari از طریق utls
- **رفع مشکل Port Mapping** — برچسب‌گذاری stream smux از misrouting جلوگیری می‌کند

---

## حالت‌های Transport

| Transport | توضیح | چه زمانی استفاده کنیم |
|---|---|---|
| `httpmux` | HTTP ساده با WebSocket upgrade + فریمینگ WS | پیش‌فرض برای ایران — شبیه ترافیک مرورگر |
| `httpsmux` | TLS + HTTP WebSocket (چرخش fingerprint utls) | قوی‌ترین — شبیه ترافیک HTTPS |
| `tcpmux` | TCP ساده | سریع ولی قابل شناسایی — برای شبکه‌های مطمئن |

---

## 📖 آموزش راه‌اندازی گام به گام

### مرحله ۱ — سرور ایران

</div>

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/amir6dev/PicoTun/main/setup.sh)
```

<div dir="rtl">

۱. گزینه **`1) Install Server (Iran)`** را انتخاب کنید
۲. حالت **`1) Automatic`** را انتخاب کنید (توصیه می‌شود)
۳. پورت تانل را وارد کنید (پیش‌فرض: `2020`)
۴. یک PSK (کلید رمز) وارد کنید — باید در سرور خارج هم یکسان باشد
۵. پروتکل انتقال را انتخاب کنید: `httpmux` توصیه می‌شود
۶. پورت‌هایی که می‌خواهید فوروارد شوند را وارد کنید
۷. بهینه‌سازی سیستم (BBR + TCP Buffers) را تأیید کنید

### مرحله ۲ — سرور خارج (Kharej)

</div>

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/amir6dev/PicoTun/main/setup.sh)
```

<div dir="rtl">

۱. گزینه **`2) Install Client (Kharej)`** را انتخاب کنید
۲. حالت **`1) Automatic`** را انتخاب کنید
۳. همان PSK سرور ایران را وارد کنید
۴. همان پروتکل انتقال سرور ایران را انتخاب کنید
۵. آدرس `IP:Port` سرور ایران را وارد کنید (مثال: `1.2.3.4:2020`)
۶. اندازه Connection Pool را انتخاب کنید (پیش‌فرض ۴ مناسب است)

---

## 🗺️ فرمت‌های Port Mapping

| فرمت ورودی | نتیجه |
|---|---|
| `8080` | پورت ۸۰۸۰ → ۸۰۸۰ |
| `1000/2000` | رنج ۱۰۰۰–۲۰۰۰ (همان پورت‌ها) |
| `5000=8080` | پورت ۵۰۰۰ → ۸۰۸۰ (مپینگ متفاوت) |
| `1000/1010=2000/2010` | رنج ۱۰۰۰–۱۰۱۰ → ۲۰۰۰–۲۰۱۰ |

---

## 📁 مسیر فایل‌های کانفیگ

</div>

```
/etc/picotun/server.yaml    ← کانفیگ سرور ایران
/etc/picotun/client.yaml    ← کانفیگ کلاینت خارج
/usr/local/bin/picotun      ← فایل باینری
```

<div dir="rtl">

### نمونه کانفیگ سرور ایران

</div>

```yaml
config_version: 3
mode: "server"
listen: "0.0.0.0:2020"
listen_ports:
  - "0.0.0.0:2020"
  - "0.0.0.0:2021"
transport: "httpmux"
psk: "your-secret-key"
profile: "speed"

maps:
  - { type: tcp, bind: "443",  target: "127.0.0.1:443" }
  - { type: udp, bind: "1234", target: "127.0.0.1:1234" }

stealth:
  random_padding: true
  min_padding: 32
  max_padding: 256
  keepalive_jitter: 3
  conn_jitter_ms: 800
  burst_split: true
  fake_traffic: true
  fake_traffic_interval: 20
```

<div dir="rtl">

### نمونه کانفیگ کلاینت خارج

</div>

```yaml
config_version: 3
mode: "client"
psk: "your-secret-key"
transport: "httpmux"
profile: "speed"

paths:
  - transport: "httpmux"
    addr: "iran-ip:2020"
    connection_pool: 4

stealth:
  random_padding: true
  burst_split: true
```

---

<div dir="rtl">

## ⚙️ پروفایل‌های عملکرد

| پروفایل | Connection Pool | Keepalive | بهترین کاربرد |
|---|---|---|---|
| `speed` | 4 | 2s | دانلود، استفاده عمومی |
| `balanced` | 4 | 2s | استفاده مختلط |
| `gaming` | 6 | 1s | بازی‌های آنلاین با تأخیر کم |
| `streaming` | 4 | 2s | ویدیو / صوت |
| `lowcpu` | 2 | 5s | سرورهای ضعیف |

---

## 🔧 مدیریت سرویس

</div>

```bash
# وضعیت
systemctl status picotun-server
systemctl status picotun-client

# ری‌استارت
systemctl restart picotun-server
systemctl restart picotun-client

# لاگ زنده
journalctl -u picotun-server -f
journalctl -u picotun-client -f
```

---

<div dir="rtl">

## 🔄 آپدیت

</div>

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/amir6dev/PicoTun/main/setup.sh)
# سپس گزینه 5) Update PicoTun را انتخاب کنید
```

---

<div dir="rtl">

## 🗑️ حذف کامل

از منوی اسکریپت گزینه **`6) Uninstall PicoTun`** را انتخاب کنید.
این گزینه باینری، کانفیگ‌ها، سرویس‌های systemd و تنظیمات کرنل را پاک می‌کند.

---

## 🔍 عیب‌یابی

<details>
<summary>اتصال برقرار نمی‌شود</summary>

- مطمئن شوید PSK در سرور و کلاینت یکسان است
- مطمئن شوید پروتکل انتقال در هر دو طرف یکسان است
- پورت تانل را در فایروال باز کنید: `ufw allow 2020/tcp`
- لاگ‌ها را بررسی کنید: `journalctl -u picotun-server -f`

</details>

<details>
<summary>IP توسط DPI بلاک می‌شود / بلاک روزانه</summary>

از transport `httpmux` یا `httpsmux` استفاده کنید و تمام قابلیت‌های stealth را فعال کنید:

</div>

```yaml
stealth:
  random_padding: true
  min_padding: 32
  max_padding: 256
  keepalive_jitter: 3
  conn_jitter_ms: 800
  burst_split: true
  fake_traffic: true
  fake_traffic_interval: 20
```

<div dir="rtl">

</details>

<details>
<summary>افت سرعت با تعداد کاربر زیاد</summary>

بافرهای SMUX و TCP را افزایش دهید:

</div>

```yaml
smux:
  max_recv: 2097152    # 2MB
  max_stream: 2097152
  frame_size: 8192     # 8KB
advanced:
  max_streams_per_session: 1024
  max_connections: 1000
  tcp_read_buffer: 131072    # 128KB
  tcp_write_buffer: 131072
```

<div dir="rtl">

</details>

<details>
<summary>قطعی‌های مکرر در بازی</summary>

</div>

```yaml
profile: "gaming"
smux:
  keepalive: 1
session_timeout: 60
```

<div dir="rtl">

</details>

<details>
<summary>Port Mapping کار نمی‌کند</summary>

مطمئن شوید سرویس مقصد روی سرور خارج در حال اجرا است و از localhost دسترسی دارد.
لاگ‌ها را بررسی کنید: `journalctl -u picotun-client -f`

</details>

---

## 📋 تاریخچه نسخه‌ها

| نسخه | تغییرات اصلی |
|---|---|
| v2.5.2 | فریمینگ RFC 6455 WS، کلید Accept صحیح، ۱۸ دامنه، UA pool به‌روز، پیش‌فرض‌های stealth قوی‌تر |
| v2.5.1 | چرخش دامنه/UA، هدر تصادفی، TCP fragmentation برای httpmux، بافرهای ۲× |
| v2.5.0 | لود بالانسر چند پورته، حالت stealth DPI، پشتیبانی +۱۲۰ کاربر، auto-migration، چرخش TLS fingerprint |
| v2.4.0 | پروفایل‌های عملکرد، failover چند IP، TLS fragmentation |

---

## پشتیبانی

- **GitHub Issues:** [github.com/amir6dev/PicoTun/issues](https://github.com/amir6dev/PicoTun/issues)
- **Developer:** [@amir6dev](https://github.com/amir6dev)

---

## لایسنس

MIT — استفاده آزاد برای اهداف شخصی و تجاری

</div>
