# 네트워크 프로필 변환기

[![Downloads](https://img.shields.io/github/downloads/daewook0401/Network_Profile/total.svg?label=Downloads&style=flat-square)](https://github.com/daewook0401/Network_Profile/releases)

간단한 네트워크 프로필 관리 도구입니다. PowerShell 스크립트를 통해 네트워크 설정(프로필)을 적용하거나 백업하는 기능을 제공합니다.

## 주요 기능

- 네트워크 프로필 적용 및 백업
- 스크립트로 자동화 가능한 구성

## 파일 구조

network_profile.ps1

## 사용법

1. PowerShell을 관리자 권한으로 실행합니다.
2. 레포지토리 루트로 이동한 뒤 스크립트를 호출합니다.

예시:

```powershell
cd C:\develop\네트워크변환기\git
powershell -ExecutionPolicy Bypass -File .\ps1\network_profile.ps1
```

스크립트에 인자가 필요한 경우, 각 스크립트의 도움말이나 상단 주석을 확인하세요.

## 요구사항

- Windows PowerShell (권장 최신 버전)
- 스크립트 실행 권한(관리자 권한 필요할 수 있음)

## 기여

이슈나 개선 제안은 GitHub 리포지토리의 Issue를 통해 보내주세요. 작은 개선이라도 환영합니다.

## 라이선스

프로젝트에 명시된 라이선스가 없으면, 사용 전 소유자에게 문의하세요.

---
작성자: 네트워크변환기 팀