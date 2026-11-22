"""توليد version.json (بيان تحديث التطبيق) بصيغة JSON صالحة مضموناً.

سبب الوجود: كان البيان يُبنى داخل workflow بـ heredoc وتهريب شاراته،
فخرج يوماً بصيغة غير صالحة (`\"android\":`) وعجز التطبيق عن تحليله،
فلم يرَ المستخدمون أي تنبيه بالتحديث. هنا يُبنى بـ json.dump فيُضمن
صلاحه، ويُتحقّق منه ذاتياً قبل الخروج.

الاستخدام:
  NAME=4.2.0 BUILD=302 REPO=owner/repo python3 tool/gen_version_manifest.py
"""
import datetime
import json
import os
import sys

name = os.environ['NAME']
build = os.environ['BUILD']
repo = os.environ['REPO']
out = os.environ.get('OUT', 'version.json')
base = f'https://github.com/{repo}/releases/download/latest'

try:
    with open('release_notes.txt', encoding='utf-8') as f:
        lines = [l.strip() for l in f.read().splitlines() if l.strip()]
except FileNotFoundError:
    lines = []

lines = lines[:3]
lines = [(l[:219].rstrip() + '…') if len(l) > 220 else l for l in lines]

manifest = {
    'version': f'{name}+{build}',
    'minSupported': os.environ.get('MIN_SUPPORTED', '3.13.0'),
    'releaseUrl': f'https://github.com/{repo}/releases/tag/latest',
    'downloads': {
        'android': f'{base}/almohaseb-arm64-v8a.apk',
        'androidArm32': f'{base}/almohaseb-armeabi-v7a.apk',
        'androidX64': f'{base}/almohaseb-x86_64.apk',
    },
    'publishedAt': datetime.datetime.now(
        datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'notes': '\n'.join(lines),
}

text = json.dumps(manifest, ensure_ascii=False, indent=2)
# تحقّق ذاتي: لا نُصدر ملفاً لا يستطيع التطبيق تحليله.
json.loads(text)
with open(out, 'w', encoding='utf-8') as f:
    f.write(text + '\n')
print('JSON صالح ✔')
print(text)
