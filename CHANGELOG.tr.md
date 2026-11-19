# Sürüm Notları

## 0.6.8

**Tek .exe ve güncelleme**
- Windows sürümü artık yanında `SDL3.dll`, `libcurl-x64.dll` veya `libcrypto-3-x64.dll` gerektirmeyen tek bağımsız `larpercord.exe` olarak derleniyor; OpenSSL, HTTP/2 (`nghttp2`), Brotli, Zstd, curl ve SDL3 dosya içine gömülü geliyor.
- Güncelleyici `sukrusk/larperCord-tr` deposuna bağlandı: yeni bir GitHub sürümü çıktığında arka planda HTTPS + SHA-256 ile otomatik indirir, çalışan `.exe` dosyasını güvenli şekilde günceller ve bir sonraki açılışta veya tek tıkla "Şimdi yeniden başlat" düğmesiyle geçiş yapar.

**Türkçe dil ve temalar**
- Tam Türkçe (`tr`) arayüz çevirisi (2160+ arayüz ve tema metni, tarih/saat biçimleri ve Yenilikler sayfası dahil).
- `terminal`, `subsolo`, `zen` ve `editorial` dahil tüm temalara canlı kamera görünümü ve arama çubuğu kontrolleri eklendi.

**Ekran, kamera ve kontrol**
- Durdurma/kapatma sırasında oluşan Windows yığın bozulması (`0xc0000374`) çökmesi ve COM başlatma/sonlandırma sırası düzeltildi.
- AnyDesk tarzı uzaktan kontrol onay penceresi tam ekran DM görünümünün üzerine alındı ve yüksek DPI/arayüz ölçeklerinde fare tıklamaları kalibre edildi.
- Karşı tarafın kamerası açıkken `receiving frames…` ekranında kalmasına yol açan SSRC filtreleme ve `media_sink_wants` hatası giderildi.
- Yayında donma ve kalite düşüşünü azaltmak için UDP paket hız dengeleme, 256 paketlik RTCP NACK yeniden iletim önbelleği, RTCP REMB bit hızı uyarlaması ve daha sık keyframe (2 saniye GOP) eklendi.
- Pencere / Uygulama seçicide `.exe` süreci gösterimi ve Windows 10/11 WASAPI Process Loopback ses yalıtımı eklendi: Pencere modunda yalnız seçili uygulamanın sesi, Tam Ekran modunda ise `larpercord.exe` sesi hariç tutularak Discord yankısı olmadan sistem sesi iletilir.

## 0.6.7

**Kayan Pencere (PiP)**
- Sohbet veya sesli aramayı ayrı, her zaman üstte duran ve boyutlandırılabilen küçük bir pencerede açma özelliği (ekranın köşesinde canlı sohbet veya arama karoları, ana pencere tepsiye küçültüldüğünde bile çalışır).

**Mesajlar, Arama ve Dışa Aktarma**
- Mesaj hatırlatıcıları (sağ tık → Bana hatırlat…, erteleme ve masaüstü bildirimi).
- Çevrimdışı yerel mesaj arama dizini (`from:`, `in:`, `mentions:`, `has:` filtreleri dahil).
- Sohbet dışa aktarma (HTML, Markdown veya JSON) ve medya kaydetme.
- Sohbet içi ses oynatıcı (dalga formu, hız kontrolü, görselleştirici) ve Ogg/Opus sesli mesaj kaydı.
- Çalınan oyunu işlem adından algılayan Rich Presence desteği ve Chrome 156 uyumlu TLS / HTTP/2 parmak izi.
