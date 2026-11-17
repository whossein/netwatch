# NetWatch

برنامه‌ی نوار منوی مک برای دیدن این‌که کدام اپ‌ها اینترنت مصرف کرده‌اند.

- آیکن و نرخ زنده‌ی پرترافیک‌ترین اپ در نوار منو
- گزارش بازه‌های ۱۰ دقیقه، ۱ ساعت، ۳ ساعت، ۱۲ ساعت، ۲۴ ساعت و ۱ ماه (دریافت، ارسال و مجموع)
- فهرست اپ‌های در حال اجرا که در آن بازه ترافیکی نداشته‌اند
- ویجت شناور روی دسکتاپ با ۵ اپ اول (قابل جابه‌جایی، بازه‌ی جدا)

## دانلود

نسخه‌ی آماده از [Releases](https://github.com/whossein/netwatch/releases/latest) (macOS 13+، اپل سیلیکون و اینتل). چون notarize نشده، دفعه‌ی اول از System Settings → Privacy & Security گزینه‌ی Open Anyway را بزنید.

## ساخت و اجرا

```bash
./build.sh
open dist/NetWatch.app
```

فقط Command Line Tools لازم است. داده‌ها در `~/Library/Application Support/NetWatch/usage.sqlite` ذخیره می‌شوند .

## نکته‌ها

- `nettop` هر ۵ ثانیه یک بار اجرا می‌شود (وقتی پنجره باز است هر ۲ ثانیه) و تفاوت هر اتصال با نمونه‌ی قبل حساب می‌شود.
- `nettop` فقط اتصال‌های باز را نشان می‌دهد، پس اتصال‌های خیلی کوتاه و آخرین لحظه‌های هر اتصال دیده نمی‌شوند (در آزمایش حدود ۴۰٪ ترافیک).
  این کسری از روی شمارنده‌ی دقیق کارت شبکه (Wi‑Fi/اترنت) به نسبت مصرف همان چند ثانیه بین اپ‌ها پخش می‌شود؛
  هر اپ حداکثر تا ۴ برابر ترافیک دیده‌شده‌اش، و بقیه در ردیف «سایر (بدون تفکیک)» می‌آید. جمع کل با مصرف واقعی کارت شبکه یکی است.
- ترافیک پروسه‌ی حامل VPN (افزونه‌های packet-tunnel مثل V2Box یا AnyConnect) شمرده نمی‌شود، چون همان ترافیک اپ‌هاست که دوباره از کارت رد می‌شود.
- پروسه‌های کمکی (مثل Google Chrome Helper) به اپ اصلی نسبت داده می‌شوند.
- دقیقه‌ی جاری در حافظه جمع می‌شود و هر دقیقه یک بار روی دیسک نوشته می‌شود؛ بسته‌های یک‌دقیقه‌ای ۲ روز و یک‌ساعته ۳۲ روز نگه داشته می‌شوند.
- ثبت داده از اولین اجرا شروع می‌شود؛ گزارش یک ماهه کم‌کم کامل می‌شود.

## مجوز

MIT — آزادانه استفاده، تغییر و توزیع کنید. متن کامل در [LICENSE](LICENSE).

---

## English

A lightweight macOS menu bar app that shows which apps are using your internet.

- Icon and live rate of the busiest app in the menu bar
- Per-app totals (download / upload) for the last 10 min, 1 h, 3 h, 12 h, 24 h and 1 month
- Running apps that had no traffic in the selected range
- Floating desktop widget with the top 5 apps (draggable, separate range)
- Shows its own CPU and energy use

### Download

Grab the latest build from [Releases](https://github.com/whossein/netwatch/releases/latest) (macOS 13+, universal). It is not notarized, so on first launch use System Settings → Privacy & Security → Open Anyway.

### Build

Requires macOS 13+ and the Xcode Command Line Tools (no full Xcode needed).

```bash
./build.sh
open dist/NetWatch.app
```

Data is stored in `~/Library/Application Support/NetWatch/usage.sqlite`.

### How it works / accuracy

- Runs `/usr/bin/nettop` every 5 s (every 2 s while the popover is open) and diffs each connection against the previous sample.
- `nettop` only lists open sockets, so very short connections and the tail of each connection are missed (about 40% in testing).
  The gap is filled from the exact 64-bit counters of the physical network interfaces (Wi‑Fi / Ethernet), split among the apps active in
  the same few seconds (each app at most 4× what was observed; the rest goes to an "Other" row). Totals match the real interface usage
  (within ~2–4% in testing).
- Traffic of VPN carrier processes (NetworkExtension packet-tunnel / app-proxy providers) is excluded, otherwise everything would be counted twice.
  VPNs that are not network extensions (e.g. command-line WireGuard) may still be double counted.
- Helper processes (e.g. Google Chrome Helper) are attributed to their parent app.
- The current minute is kept in memory and written once per minute; minute buckets are kept for 2 days, hourly buckets for 32 days.

### License

MIT — see [LICENSE](LICENSE).
