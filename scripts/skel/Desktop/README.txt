Bu imaj hakkında
================

Bu masaüstü, önceden hazırlanmış Arch Linux ARM tabanlı bir Raspberry Pi 5
imajından geliyor. Bilmen faydalı olacak birkaç nokta:

1) Kullanıcı
-------------
Bu imajda TEK kullanıcı var: root (şifre: root). Sistem otomatik olarak
root oturumuyla Plasma masaüstüne giriş yapıyor. Şifreni değiştirmek
istersen:

    passwd

2) Ollama (yapay zeka modelleri)
---------------------------------
gemma3:1b ve gemma3:4b modelleri zaten kurulu. Terminal'den:

    ollama run gemma3:4b
    ollama run gemma3:1b

Modeller /srv/ollama/models altında tutuluyor (OLLAMA_MODELS ile servise
bildiriliyor).

Ollama GÜNCELLEMESİ pacman ile YAPILMAZ (apt deposu yok, manuel kurulum).
Güncellemek için:

    curl -fsSL https://ollama.com/install.sh | sh

3) Tailscale
------------
Tailscale kurulu ama bağlanmadı (otomatik açılmıyor, kasıtlı). Bağlanmak için
terminal'den:

    sudo tailscale up

4) Klavye / yerelleştirme
---------------------------
Sistem dili tr_TR.UTF-8, klavye düzeni trq (Türkçe Q) olarak ayarlandı.
Saat dilimi Europe/Istanbul.

5) Bu dosya
-----------
İşini bitirdiğinde bu dosyayı silebilirsin.
