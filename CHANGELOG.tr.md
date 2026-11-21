# Sürüm Notları

## 0.7.0

**Ağ, DoH ve GoodbyeDPI**
- Uygulama içi Şifreli DNS (DoH — Cloudflare `1.1.1.1` / Google `8.8.8.8` -> `CURLOPT_RESOLVE`) ve sürücüsüz OpenSSL TLS `ClientHello` SNI paket ayrıştırma (`tls_chrome.c` BIOS filtresi, Chrome 156 JA4 korunarak) varsayılan olarak eklendi; REST, Gateway, ses/kamera ve ekran paylaşımı (`*.discord.media`) bağlantılarında çalışır.
- Ses ve görüntü WebSocket (`voice.zig` `*.discord.media`) bağlantıları da artık proxy, DoH ve TLS SNI ayrıştırma yolundan geçiyor; böylece kısıtlı ağlarda kamera ve ekran paylaşımı da sorunsuz açılıyor.
- Windows için resmi `ValdikSS/GoodbyeDPI v0.2.3rc3-2` entegrasyonu eklendi: Ayarlar → Ağ ve Giriş ekranından SHA-256 doğrulamalı tek tık kurulum, Türkiye profilleri (`TR Önerilen -5`, `Superonline -9`, `Sadece DPI`, `Evrensel`), UAC ile başlat/durdur ve açılışta otomatik başlatma seçeneği sunuyor.

**Ekran Paylaşımı ve Kamera**
- Sabit masaüstü/pencere yayınında yakalama donduğunda son NV12/D3D11 karesini 250 ms aralıklı koruma ve `skey_cb` keyframe taleplerinde anında yeniden kodlama desteği eklendi; async H.264 MFT gecikmesi yarıya indirildi (`6ms`/`8ms`), 512 yuvalı RTP hız dengeleyiciyle 1080p60/4K60 akıcılığı artırıldı ve H.264 `<=1080p` çözünürlüklerde düşük gecikmeli SW kod çözücü (`~10x` daha hızlı) önceliklendirildi.
- Yayın seçiciye **Yenile**, 6 monitöre kadar çoklu monitör seçimi, canlı bit hızı (`Otomatik`, `4M`, `8M`, `15M`, `25M` Mbps), **Fare imlecini yakala** (`IGraphicsCaptureSession2`) ve **Kendi yayınımı ön izle** seçenekleri ile pencere listesi kaydırma çubuğu eklendi.
- Ses ve Video Ayarları, kamera seçimi + canlı kamera testi/ön izleme, yatay aynalama, bit hızı ve donanım hızlandırma (`cam_hw` / `hw_decode_pref`) ile genişletildi.
- Çağrı ızgarası ve yayın sahnesine **Sığdır/Doldur (Zoom)**, **Kare İste (PLI)**, **Kaynak Değiştir**, **Kamera Büyüt** ve kamera/paylaşım düğmelerine sağ tık hızlı menüleri eklendi.

## 0.6.9

**Kamera, ekran paylaşımı ve resmi Discord uyumu**
- DAVE E2EE başlangıç kilidi düzeltildi (`OP 4` SessionDescription paketinden önce gelen `OP 25` dış gönderici paketi artık bekletilip işleniyor) ve Go Live MLS `group_id` değeri (`rtc_channel_id` farklı olsa bile `rtc_server_id - 1`) ile `STREAM_CREATE` sırası düzeltildi.
- Resmi Discord masaüstü ve web istemcilerinin giden kamera ve ekran yayınlarını çözebilmesi için `0xBEDE` RTP başlık uzantıları (`abs-send-time`, `playout-delay`, `video-content-type`, `rid`), RFC 4588 RTX yeniden iletimi (`video_rtx_ssrc` + `repaired-rid`) ve 5 saniyelik RTCP Sender Report paketleri eklendi.
- Windows H.264 Media Foundation kodlayıcıları artık WebRTC uyumlu Constrained Baseline profili (`profile-level-id=42e01f`) istiyor; `OP 12` `"video"` sinyalizasyonu (durunca `"streams":[]`) ve Go Live `SOUNDSHARE` (`speaking=2`) güncellendi.
- DAVE dönem geçişleri (`OP 24`, ön-DAVE kuyruğu temizleme + keyframe isteği) iyileştirildi ve `video_diag.log` çıktısına `skip` ile MLS `merr` sayaçları eklendi.

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
