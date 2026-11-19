<div align="center">

# larperCord

**Windows ve Linux için ~130 MB RAM kullanan, arayüzü tamamen tema dosyalarıyla şekillenen yerli Discord istemcisi.**

Zig · SDL3 · Dear ImGui · FreeType · Electron yok

**Türkçe** · [English](README.en.md) · [Português](README.pt-BR.md)

![larperCord temaları](docs/themes.png)

*Aynı tek çalıştırılabilir dosya, yalnızca `.kdl` tema dosyası değişir. 11 yerleşik temanın her birinin aydınlık ve karanlık kipi vardır.*

</div>

> [!WARNING]
> **Üçüncü parti istemciler Discord Hizmet Şartları'na aykırıdır** ve hesabınızın kısıtlanmasına yol açabilir.
> Kendi sorumluluğunuzda, tercihen ikincil bir hesapla kullanın. Token yapılandırılmadığında uygulama sahte verilerle **demo kipinde** çalışır.

## Öne Çıkan Özellikler

### Tek `.exe` ve GitHub Üzerinden Otomatik Güncelleme
- **Tek bağımsız Windows `.exe` dosyası:** `SDL3.dll`, `libcurl-x64.dll` veya `libcrypto-3-x64.dll` dosyalarına ihtiyaç duymaz; SDL3, libcurl (HTTP/2, Brotli, Zstd), OpenSSL, Opus, libwebp, FreeType, RNNoise ve FriBidi doğrudan dosya içine gömülüdür. İstediğiniz klasöre veya masaüstüne tek dosya olarak koyup çalıştırabilirsiniz.
- **Doğrudan otomatik güncelleme:** Varsayılan olarak açık gelen arka plan güncelleyici her açılışta [sukrusk/larperCord-tr sürümlerini](https://github.com/sukrusk/larperCord-tr/releases) HTTPS üzerinden kontrol eder, SHA-256 doğrulaması yapar, yeni sürümü indirir ve çalışan `.exe` dosyasını güvenli biçimde değiştirir (sonraki açılışta veya tek tıkla "Şimdi yeniden başlat" düğmesiyle hemen devreye girer).
- **Otomatik GitHub Release akışı:** Depodaki `src/core/version.zig` sürüm numarası yükseltildiğinde veya `v*` etiketi gönderildiğinde GitHub Actions otomatik olarak tek dosyalı Windows `.exe` ve taşınabilir Linux ikilisini derleyip yeni sürüm olarak yayınlar.

### 4K Ekran Paylaşımı, Canlı Kamera ve Yankısız Ses Yakalama
- **Donanım hızlandırmalı 4K/60fps video:** Windows üzerinde WGC / DXGI masaüstü yakalama, Media Foundation NVENC/H.264/HEVC/AV1 donanım kodlama/çözme (donanım yoksa yazılım MFT yedeği) ve düşük bellekli NV12 kare hattı.
- **Takılma ve kalite düşüşüne karşı ağ koruması:** UDP paket hız dengeleme (`drainVideoPacer`), 256 paketlik RTCP Generic NACK yeniden iletim önbelleği, RTCP REMB bit hızı uyarlaması ve sık keyframe (2 saniye GOP).
- **Uygulama / Pencere seçici ve WASAPI Process Loopback (Yankısız ses):** Ekran paylaşımı penceresinde çalışan `.exe` süreçlerini listeler; **Pencere / Uygulama** kipinde yalnızca seçtiğiniz oyun/uygulamanın (örneğin `cs2.exe`) sesini yakalar, **Tam Ekran** kipinde ise `larpercord.exe` sürecinin Discord sesini hariç tutarak karşıya yankı gitmesini önler.
- **Tüm temalarda kamera görünümü:** `classico`, `vidro`, `terminal`, `subsolo`, `orbital`, `editorial`, `bolhas`, `zen`, `papel`, `escritorio` ve `cupertino` dahil tüm temalarda kamera karoları ve durum çubuğu kamera/paylaşım kontrolleri yer alır.
- **Şifreli AnyDesk tarzı uzaktan kontrol:** X25519 + XChaCha20-Poly1305 uçtan uca şifreli tünel, yalnızca fare veya tam kontrol için belirgin onay penceresi, yüksek DPI/ölçek desteği ve tek tuşla acil durdurma (`F8`).

### Hafiflik, Görünüm ve Discord Özellikleri
- **~130 MB RAM, boşta %0–0.4 CPU:** Tarayıcı veya Electron yoktur; olay gelmedikçe `SDL_WaitEvent` içinde uyur, yazı tiplerini dosya eşleme (`mmap` / `MapViewOfFile`) ile paylaşır.
- **11 tema ve anlık sıcak yenileme:** `.kdl` dosyasını düzenleyip kaydettiğiniz anda pencere yeniden derleme gerekmeden güncellenir.
- **Tam Türkçe (`tr`) arayüz:** Tüm menüler, ayarlar, tema açıklamaları, zaman damgaları (`gün/ay/yıl`, `3 gün önce`) ve "Yenilikler" sayfası Türkçedir.
- **Gerçek Discord Gateway + Chrome TLS uyumu:** `RESUME`, `zlib-stream`, rate limit korumalı REST ve Chrome 156 TLS (JA4) / HTTP/2 parmak izi uyumu.
- **E2EE sesli aramalar ve DM/grup aramaları:** Ses ağ geçidi v8, DAVE/MLS uçtan uca şifreleme, 48 kHz Opus stereo, kişi bazlı ses düzeyi/gürültü temizleme/ses dengeleme mikseri ve mikrofonda yerel **RNNoise** gürültü engelleme.
- **Zengin sohbet deneyimi:** Kayan pencere (PiP), sesli mesaj kaydı (.ogg Opus) ve dalga formlu ses oynatıcı, mesaj hatırlatıcıları, çevrimdışı yerel arama dizini (`Ctrl+F`), HTML/Markdown/JSON sohbet dışa aktarma, Lua eklentileri, özelleştirilebilir köşe maskotu, kanal sekmeleri ve komut paleti (`Ctrl+K`).

---

## İndirme ve Kurulum

**Doğrudan indirme (Tek `.exe`, DLL gerektirmez):**
- **Windows 10/11 (x64 tek dosya):** [larpercord-windows-x86_64.exe](https://github.com/sukrusk/larperCord-tr/releases/latest/download/larpercord-windows-x86_64.exe)
- **Linux (x86_64 taşınabilir):** [larpercord-linux-x86_64](https://github.com/sukrusk/larperCord-tr/releases/latest/download/larpercord-linux-x86_64)
- **Tüm sürümler:** [GitHub Releases](https://github.com/sukrusk/larperCord-tr/releases)

> [!NOTE]
> Windows dosyası kod imzalı olmadığı için ilk açılışta SmartScreen **"Windows bilgisayarınızı korudu"** uyarısı gösterebilir. **Ek bilgi → Yine de çalıştır** seçeneğiyle açabilirsiniz. Güncellemelerin çalışabilmesi için uygulamayı `C:\Program Files` yerine yazma izninizin olduğu bir klasörde (ör. Masaüstü veya `%LOCALAPPDATA%\Programs\larperCord`) tutun.

### Tek Satırla Kurulum

**Windows 10/11 (PowerShell, yönetici izni gerekmez):**

```powershell
irm https://raw.githubusercontent.com/sukrusk/larperCord-tr/main/install.ps1 | iex
```

Kaldırmak için `-Uninstall`, tüm ayar ve kaydedilmiş hesapları da silmek için `-Purge`:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/sukrusk/larperCord-tr/main/install.ps1))) -Uninstall
```

**Linux (`~/.local/bin`):**

```bash
curl -fsSL https://raw.githubusercontent.com/sukrusk/larperCord-tr/main/install.sh | sh
```

### Hesap Bağlama ve Gizlilik
Token **asla** koda, günlüğe veya hata mesajlarına yazılmaz; Windows'ta Kimlik Bilgisi Yöneticisi'nde (`larperCord/account/<ID>`), Linux'ta sistem anahtarlığında saklanır. Tek seferlik ortam değişkeniyle başlatmak için:

```powershell
$env:LARPER_TOKEN = [Net.NetworkCredential]::new('', (Read-Host 'Token' -AsSecureString)).Password
.\larpercord-windows-x86_64.exe
Remove-Item Env:LARPER_TOKEN
```

---

## GitHub Üzerinden Otomatik Güncelleme Nasıl Çalışır?

Bu fork (`sukrusk/larperCord-tr`) için hem istemci hem CI tam otomatik yapılandırılmıştır:

1. Kodunuzu güncelleyip `src/core/version.zig` içindeki sürüm numarasını (ör. `"0.6.8"` → `"0.6.9"`) yükseltin ve `main` dalına pushlayın (veya `git tag v0.6.9 && git push origin v0.6.9`).
2. [release.yml](.github/workflows/release.yml) iş akışı Windows için tek `.exe` (`-Dsingle-exe=true`) ve Linux için taşınabilir ikiliyi derleyip `SHA256SUMS` ile birlikte otomatik olarak GitHub Release yayınlar.
3. Kullanıcılar uygulamayı açtığında güncelleyici yeni sürümü indirir, SHA-256 doğrulamasını yapar ve çalışan `.exe` dosyasını otomatik değiştirir.

---

## Kaynaktan Derleme

Gereksinimler: **Zig 0.17.0**. Windows tek `.exe` derlemesi Linux veya Windows + Git Bash/MSYS2/CMake/Ninja/Perl üzerinden şu komutlarla alınabilir:

```bash
tools/windows_deps.sh && tools/windows_static_deps.sh
zig build -Dtarget=x86_64-windows-gnu -Dsingle-exe=true
```

Testleri çalıştırmak için:

```bash
zig build test --summary all
python3 tools/i18n_strings.py --lang tr --check --strict
```

## Kısayollar

`Ctrl+K` komut paleti · `Ctrl+,` ayarlar · `Ctrl+I` gelen kutusu · `Ctrl+F` arama · `Ctrl+Shift+S` kaydedilenler · `F2` sonraki tema · `Ctrl+Tab` sekmeler · `Alt+1…9` sekme seç · `Ctrl+W` sekme kapat · `Ctrl+Shift+M` mikrofon sustur · `Ctrl+Shift+D` sağırlaştır · `F8` uzaktan kontrol acil durdurma.

## Lisans

larperCord, [GNU General Public License v3.0](LICENSE) (`GPL-3.0-only`) ile lisanslanmıştır. Üçüncü parti bileşenler (`third_party/`) kendi lisanslarını korur: Dear ImGui / dear_bindings (MIT), RNNoise (BSD), GNU FriBidi (LGPL-2.1+), dr_libs (MIT-0 / public domain).
