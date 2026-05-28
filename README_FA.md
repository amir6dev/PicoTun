<div dir="rtl">

# PicoTun — تانل رمزنگاری‌شده معکوس

[![Version](https://img.shields.io/badge/version-v2.5.1-blue)](https://github.com/amir6dev/PicoTun/releases)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Linux-lightgrey)](#)

> تانل معکوس رمزنگاری‌شده با قابلیت دور زدن DPI، لود بالانسینگ چند پورته و پشتیبانی از تعداد کاربر بالا

---

## ✨ ویژگی‌ها

- **رمزنگاری AES-256-GCM** — تمام ترافیک رمزنگاری می‌شود
- **دور زدن DPI** — جعل هدرهای HTTP/HTTPS، چرخش دامنه، فرگمنتاسیون TCP
- **مالتی‌پورت** — سرور ایران می‌تواند روی چند پورت همزمان گوش بدهد
- **IP بکاپ** — در صورت بلاک شدن IP اصلی، به‌صورت خودکار به IP پشتیبان سوئیچ می‌کند
- **بهینه‌سازی کرنل** — فعال‌سازی BBR و تنظیم TCP Buffer
- **پشتیبانی از +120 کاربر هم‌زمان**
- **سرویس Systemd** با ری‌استارت خودکار

---

## 📋 پیش‌نیازها

- سیستم‌عامل Linux (Ubuntu/Debian/CentOS)
- دسترسی root
- حداقل یک سرور ایران و یک سرور خارج

---

## 🚀 نصب سریع

روی **هر دو سرور** (ایران و خارج) این دستور را اجرا کنید:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/amir6dev/PicoTun/main/setup.sh)
```

---

## 📖 آموزش راه‌اندازی گام به گام

### مرحله ۱ — نصب روی سرور ایران

۱. اسکریپت را اجرا کنید
۲. از منوی اصلی گزینه **`1) Install Server (Iran)`** را انتخاب کنید
۳. حالت **`1) Automatic`** را انتخاب کنید (توصیه می‌شود)
۴. **پورت تانل** را وارد کنید (پیش‌فرض: `2020`)
۵. یک **PSK (کلید رمز)** دلخواه وارد کنید — این کلید باید در سرور خارج هم یکسان باشد
۶. پروتکل انتقال را انتخاب کنید:
   - `httpmux` — جعل HTTP (توصیه می‌شود برای دور زدن فیلترینگ)
   - `httpsmux` — جعل HTTPS با TLS (قوی‌ترین حالت)
   - `tcpmux` — TCP ساده (سریع‌تر ولی قابل شناسایی)
۷. **پورت‌هایی که می‌خواهید فوروارد شوند** را وارد کنید
8. بهینه‌سازی سیستم را تأیید کنید

### مرحله ۲ — نصب روی سرور خارج (Kharej)

۱. اسکریپت را اجرا کنید
۲. از منوی اصلی گزینه **`2) Install Client (Kharej)`** را انتخاب کنید
۳. حالت **`1) Automatic`** را انتخاب کنید
۴. همان **PSK** که در سرور ایران وارد کردید را وارد کنید
۵. همان **پروتکل انتقال** سرور ایران را انتخاب کنید
۶. **آدرس IP:Port سرور ایران** را وارد کنید (مثال: `1.2.3.4:2020`)
۷. **اندازه Connection Pool** را انتخاب کنید (پیش‌فرض: 4 مناسب است)

---

## 🗺️ مثال‌های پورت مپینگ

| فرمت ورودی | توضیح |
|---|---|
| `8080` | پورت ۸۰۸۰ → ۸۰۸۰ |
| `1000/2000` | رنج پورت ۱۰۰۰ تا ۲۰۰۰ (same) |
| `5000=8080` | پورت ۵۰۰۰ → ۸۰۸۰ (مپینگ متفاوت) |
| `1000/1010=2000/2010` | رنج ۱۰۰۰-۱۰۱۰ → ۲۰۰۰-۲۰۱۰ |

---

## ⚙️ پروفایل‌های عملکرد

| پروفایل | کاربرد |
|---|---|
| `speed` | حداکثر throughput (پیش‌فرض) |
| `balanced` | تعادل بین سرعت و پایداری |
| `gaming` | تأخیر فوق‌کم (برای بازی) |
| `streaming` | بهینه برای ویدیو/صوت |
| `lowcpu` | مصرف CPU کم (سرورهای ضعیف) |

---

## 🔧 مدیریت سرویس

```bash
# مشاهده وضعیت
systemctl status picotun-server
systemctl status picotun-client

# ری‌استارت
systemctl restart picotun-server
systemctl restart picotun-client

# مشاهده لاگ زنده
journalctl -u picotun-server -f
journalctl -u picotun-client -f
```

---

## 📁 مسیر فایل‌های کانفیگ

```
/etc/picotun/server.yaml   ← کانفیگ سرور ایران
/etc/picotun/client.yaml   ← کانفیگ کلاینت خارج
/usr/local/bin/picotun     ← فایل باینری
```

---

## 🛡️ قابلیت‌های ضد DPI (نسخه v2.5.1)

- **Domain Rotation** — تغییر دامنه در هر اتصال از بین ۱۶ دامنه معتبر
- **User-Agent تصادفی** — تغییر مرورگر جعلی در هر کانکشن
- **هدر تصادفی** — ترتیب هدرهای HTTP به‌صورت تصادفی چیده می‌شود
- **TCP Fragmentation** — تقسیم بسته‌ها به chunks 64-191 بایتی
- **Padding تصادفی** — اضافه کردن 16-128 بایت داده تصادفی
- **Keepalive Jitter** — نویز ±۲ ثانیه‌ای در heartbeat
- **Fake Traffic** — تولید ترافیک ساختگی هر ۳۰ ثانیه

---

## 🔄 آپدیت

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/amir6dev/PicoTun/main/setup.sh)
# سپس گزینه 5) Update PicoTun را انتخاب کنید
```

---

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
<summary>DPI ترافیک را بلاک می‌کند</summary>

- از `httpmux` یا `httpsmux` به‌جای `tcpmux` استفاده کنید
- دامنه HTTP Mimicry را به یک سایت محبوب تغییر دهید
- گزینه Traffic Obfuscation را فعال کنید

</details>

<details>
<summary>افت سرعت زیاد</summary>

- بهینه‌سازی سیستم (BBR + TCP Buffers) را اجرا کنید
- اندازه Connection Pool را افزایش دهید (6 یا 8)
- پروفایل `speed` را انتخاب کنید

</details>

<details>
<summary>قطعی‌های مکرر در بازی</summary>

- از پروفایل `gaming` استفاده کنید
- Keepalive Interval را به ۱ ثانیه کاهش دهید

</details>

---

## 📞 پشتیبانی

- **GitHub Issues:** [github.com/amir6dev/PicoTun/issues](https://github.com/amir6dev/PicoTun/issues)
- **Developer:** [@amir6dev](https://github.com/amir6dev)

---

## 📜 لایسنس

MIT License — استفاده آزاد برای اهداف شخصی و تجاری

</div>
