# Sürüm Notları

## 0.8.3

**Canlı Yayın ve Ses Kontrolü**
- Go Live ekranına yayın kesilmeden anında uygulanabilen canlı **Yayın Ayarları** menüsü eklendi (`720p`/`1080p`/`1440p`/`4K`, `30`/`60` FPS, bitrate, performans ön ayarı, sistem sesi, imleç, öz izleme ve pencere/ekran kaynağı değiştirme — `updateNativeCapture` + `OP 12`).
- İzleyici HUD'una, ses mikserine (`popup.zig`) ve kullanıcı sağ tık menüsüne kalıcı bağımsız **Yayın Sesi** seviye çubuğu (`%0`–`%200`) ve susturma anahtarı eklendi (`settings.kdl`: `stream_volume`, `stream_muted`, `watch_voice` senkronizasyonu).
- `stream_voice` ve `watch_voice` bağlantılarının çift mikrofon açması ve ses durumu bildirimlerini bozması engellendi.

**Yayın ve Çoklu Kamera**
- Paylaşılan tek global codec yerine SSRC başına RTP payload-type codec yönlendirmesi (`101=H.264`, `103=VP8`, `105=VP9`, `107=HEVC`, `109=AV1` + RTX) ve genişletilmiş video yuvaları (`16` `VideoRxSlot`/`DecSlot`, `32` halka yuvası, `12` `peer_cams`, `17` medya sink) ile ekran yayını ve kameralar aynı anda hatasız çözülür.
- Hem DM/metin görünümünde hem tam ekranda yayın izlerken yan yana bölünmüş sahne (`call_grid.zig`, `stream_view.zig`) ve sağ altta kayan kamera şeridi (`drawCamOverlayStrip`, `stream_show_cams` anahtarı ve AnyDesk uzaktan kontrolünden hariç) eklendi.
- Aktif kamera karolarındaki kullanıcı adı yazısı yüzü kapatmayacak şekilde alt-sol koyu etikete taşındı (`call_grid.zig`).

**Akıcı Arayüz ve Tema Geçişi**
- Fare hover tepkisi 60 FPS'e çıkarıldı (`MousePace.interval_ms = 16`); ayarlar açılış/kapanış yakınlaştırma animasyonu (`settings.zig`), DM simge göstergesi (`comp_rail.zig`) ve sesli kanal üye hover geçişleri (`comp_channels.zig`) yumuşatıldı.
- Tema değiştirirken `190 ms` yumuşak geçiş (crossfade) eklendi (`app.zig`, `root.zig`) ve tüm yeni dizgelerin Türkçe çevirisi (`i18n/tr.kdl`) tamamlandı.

## 0.8.2

**Discord Yayını İzleme**
- Ses kanalı kenar çubuğuna tıklanabilir `[CANLI]` etiketi (`comp_channels.zig`), çağrı kartlarına `▶ CANLI` rozeti (`call_grid.zig`) ve sağ tık **"Yayını İzle"** eylemleri eklendi; tıklandığında kanala katılıp Discord Go Live yayınını otomatik açar (`app.zig`, `popup.zig`).
- `voice.zig` içindeki izleyici `watch_voice` `OP 0 IDENTIFY` yükü `setWatchStreamMode` ile düzeltildi (izleyicinin boş yayın ilan etmesi engellendi) ve `discord.zig` tarafında `STREAM_CREATE` gelmeden yanlış `watch_rtc_server` tahmini yapılması kaldırıldı.
- Resmi Discord istemcisi yayınlarını izlemek için `H264` yanında Media Foundation (`VP80`/`VP90`, `mf_codec.zig`) ve FFmpeg `RawDecoder` (`ffmpeg.zig`) ile `VP8`/`VP9`/`AV1` çözme desteği (`video_rtp.zig`, `call_json.zig`) eklendi.
- `OP 12 VIDEO` mesajlarında `audio_ssrc` için DAVE anahtarı kaydı yapıldı, RFC 4588 RTX paketleri (`unwrapRtx`) açıldı ve `voice.zig::onRtp` içinde 96 altındaki payload türlerinin düşürülmesi düzeltildi.

**Akıcı AnyDesk ve Kameralar**
- AnyDesk'teki ekran kırpışması ve fare kayması (`remote_ctrl.zig`, `live_video.zig`, `stream_view.zig`) giderildi: `watch_slot` üzerinde P2P ve SFU çakışması engellendi, P2P çözme ayrı `viewerDecMain` iş parçacığına taşındı, `4 MiB` UDP arabelleği ve toplu soket boşaltma eklendi, `mouse_move` birleştirme ile `sendVideoAu` kare başı tek kilit kullanıldı ve kenarlarda giriş iptali yerine `mapViewportToNormalizedClamped` ile sınırlama yapıldı.
- DXGI ekran kırpışması ve keyframe taşması düzeltildi: `dxgi_cap.zig` üzerinde `Nv12GpuCtx` üçlü arabelleğe alındı, masaüstü güncellenmeden gelen siyah 0. kare atlandı, `mf_codec.zig` `ProcessInput` sonrası `CODECAPI_AVEncVideoForceKeyFrame` sıfırlandı ve bozuk paketler `FrameAssembler.takeAbandoned()` ile yakalandı.
- Web kamerası donmaları (`live_video.zig`) çözüldü: sıkıştırmasız piksel formatları `MJPG` önüne alındı, `MJPG` için `stbi_load_from_memory` -> NV12 yedek çözücüsü eklendi, 2,5 saniye kilitlenen kamerayı yeniden açan gözcü eklendi ve `pollOutput()` kuyruğu yeni kareden önce boşaltıldı.
- DAVE geçişleri ve paket kaybındaki SFU kamera donmaları (`voice.zig`) giderildi: katılımcılar arası küresel `dec_wait_key` blokajı kaldırıldı, düşen/eksik/çözülemeyen karelerde SSRC bazlı PLI isteği ve `tx_wait_key` eklendi, `dec_ring` kuyruğu 16 kareye çıkarıldı.

## 0.8.1

**Video ve Kamera Sekmesi**
- Kamera seçimi, canlı ön izleme, kameraya özel çözünürlük/FPS/bit hızı ayarları, ekran paylaşımı performans profilleri, yakalama motoru (`Auto`/`DXGI`/`WGC`), keyframe aralığı ve uzaktan kontrol artık doğrudan **Ayarlar → Video ve Kamera** sekmesinde (Ses'in hemen altında) yer alıyor.
- Video ve Kamera sekmesi açıldığında bağlı web kameraları otomatik algılanıp doğrudan listelenir; önceki "önce algıla düğmesine bas" adımı kaldırıldı.
- Ses çubuğu ve çağrı kontrollerindeki kamera/paylaşım düğmelerine sağ tık kamera/seçenek menüsü ipucu ve köşe ok göstergesi eklendi.

**AnyDesk, İmleç ve Çoklu Ekran**
- DXGI ekran paylaşımında görünmeyen fare imleci düzeltildi: `dxgi_cap.zig` artık tek renkli (AND/XOR metin imleci dahil), 32-bit renkli ve maskeli donanım imleçlerini doğrudan GPU dokusuna işler (`GetCursorInfo` 0. kare desteği ve canlı aç/kapat ile); `wgc_cap.zig` ise başlatmadan önce imleç bayrağını ayarlar ve pencere boyutu/DPI değişiminde havuzu dinamik olarak yeniler (`Recreate`).
- Başlığı 96 baytı geçen veya Türkçe/UTF-8 karakter içeren tarayıcı/uygulama pencerelerini sessizce düşüren `wgc_cap.zig::enumWinCb` hatası giderildi (`utf16ToUtf8Truncated`, `WS_EX_TOOLWINDOW` filtresi, 48 pencereye kadar liste); yayın seçiciye canlı monitör/uygulama sayısı, çoklu ekranda Sol/Sağ/Ana konum etiketleri ve sağ tık menüsüne doğrudan **"Uygulama / Pencere Seç…"** kısayolu eklendi.
- 2 ve 3 monitörde yaşanan AnyDesk koordinat hataları düzeltildi: `input_inject.zig` yakalanan monitör (`GetMonitorInfoW`) veya uygulama penceresi (`DWMWA_EXTENDED_FRAME_BOUNDS`) alanını negatif sanal masaüstü koordinatları dahil birebir eşler; Numpad ve ISO `<>|` (`0x56`) tuşları ile atomik tıklama desteği eklendi.
- AnyDesk P2P altyapısı güçlendirildi: video kodlamasını bloklamamak için `SendInput` mutex dışına alındı, canlı P2P gecikme ölçümü (`AnyDesk 12ms`), kesirli tekerlek biriktirici, yan fare düğmeleri (`X1`/`X2`), odak kaybında otomatik tuş bırakma, Google/Cloudflare çift STUN yedeği ve izleyicide canlı **`M1`/`M2`/`M3`** monitör değiştirme düğmeleri eklendi.

## 0.8.0

**Minimum RAM ve Bellek Optimizasyonu**
- `mem_tune.zig` modülüne gerçek Windows yığın sıkıştırma (`GetProcessHeaps` + `HeapCompact`) ve çalışma kümesi temizliği (`SetProcessWorkingSetSize`) eklendi; kamera, ekran paylaşımı veya çağrı kapatıldığında biriken Media Foundation/NVENC/COM belleği işletim sistemine geri verilir.
- Çıkan kullanıcıların donanım/yazılım video kod çözücülerini bekletmeden serbest bırakmak için `removeVideoUser` çoklu düşürme kuyruğuyla `decThreadMain` iş parçacığını uyandıracak şekilde düzeltildi; WGC yakalama havuzu `3`'ten `2` yüzeye indirildi, `HwEncoder.out_buf` boyutu çözünürlüğe göre ölçeklendi (`512 KiB` 720p altı, `1 MiB` 1080p, `2 MiB` 4K), yalnızca ses çağrılarında UDP soket arabelleği `512 KiB` ile sınırlandı ve kamera yakalama->kodlayıcı arasındaki tam NV12 bellek kopyası işaretçi takasıyla sıfırlandı.
- Ayarlar → Performans altına **Minimum RAM modu**, canlı **Fiziksel RAM (Çalışma Kümesi)** göstergesi, genişletilmiş bellek sınırları (`8..128 MB` görseller, `2..32 MB` GIF'ler, `300..5000` mesajlar), **Belleği şimdi temizle** düğmesi ve pencere açıkken boşta kalan yerel arama dizininin otomatik serbest bırakılması eklendi.

**Ekran, Kamera ve Discord Uyumu**
- Kamera için ekran paylaşımından bağımsız çözünürlük (`480p`/`720p`/`1080p`/Yayınla eşle), kare hızı (`15`/`30`/`60 FPS`) ve bit hızı (`Auto`, `2..10 Mbps`) ayarları eklendi; böylece 4K ekran paylaşımı açıkken web kamerası gereksiz 4K NV12 yüküne zorlanmaz.
- Ayarlar → Ses ve Video altına kodlayıcı profili (`Hız` CBR / `Dengeli` CBR / `Kalite` PeakConstrainedVBR + `QualityVsSpeed`), ekran yakalama motoru (`Auto` / `DXGI` / `WGC`), sabit ekranda kare hızı (`2` / `4` / `10 FPS`) ve keyframe GOP aralığı (`1s` / `2s` / `4s`) eklendi; sahne HUD'una canlı süreç RAM bilgisi eklendi.
- Resmi Discord istemcisinde kamera ve ekran paylaşımının sorunsuz görünmesi için Discord SFU üzerinde `OP 1`, `OP 4` (`video_codec`), `OP 12`, DAVE E2EE ve RTP paketleme uçtan uca `H.264` ile hizalandı; PLI/FIR keyframe istekleri gerçek bir IDR kare çıkana dek kalıcı hale getirildi; %100 sabit masaüstünde ilk kare gecikmesine karşı otomatik DXGI → WGC geçişi, Discord `STREAM_DELETE` neden bildirimleri ve ses/görüntü UDP trafiği için RFC 1928/1929 SOCKS5 `UDP ASSOCIATE` tüneli eklendi.
- Çağrı ekranındaki kırmızı ayrıl düğmesinin köşe maskotu tarafından yakalanma hatası (`QA_SUITE=call`) giderildi, eski belgeler güncellendi ve Türkçe çeviriler eksiksiz tamamlandı.

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
