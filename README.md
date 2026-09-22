# PumpnGrow — Raspberry Pi 설치 및 업데이트

포유자돈 급이기 HMI(PumpnGrow)의 **설치 스크립트와 배포 패키지**만 제공하는 저장소입니다.

## 최초 설치 (Raspberry Pi OS 64-bit GUI, 인터넷 연결 상태)

GUI 터미널에서 한 줄 실행:

```bash
curl -fsSL https://raw.githubusercontent.com/BlessingQ/pump_n_grow_public/main/install/setup_pumpngrow.sh | bash
```

설치가 끝나면 `sudo reboot`로 한 번 재부팅합니다.

오프라인 장비는 `install/` 폴더를 USB로 복사한 뒤 `bash ~/install/setup_pumpngrow.sh`를 실행합니다.

## 업데이트

앱의 **설정 → 업데이트** 화면에서 새 버전을 확인하고 설치합니다. 최신 패키지는 [Releases](https://github.com/BlessingQ/pump_n_grow_public/releases/latest)에 있습니다.

- `pumpngrow-linux-arm64.zip` — 앱 패키지
- `pumpngrow-linux-arm64.zip.sha256` — 무결성 검증용 체크섬
