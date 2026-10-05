#!/bin/bash
# سكريبت أتمتة رفع التعديلات إلى GitHub لبدء بناء الـ APK تلقائياً

REPO_URL="${GITHUB_REPO_URL:-https://github.com/monerqaid950-debug/almohaseb.git}"

echo "🔄 جاري إضافة التعديلات..."
git add .

echo "📝 جاري حفظ التعديلات (Commit)..."
COMMIT_MSG=${1:-"Auto-update from AI Studio: Fix & Enhance"}
git commit -m "$COMMIT_MSG"

echo "🚀 جاري الرفع إلى GitHub (فرع main)..."
git branch -M main
git push -u "$REPO_URL" main --force

if [ $? -eq 0 ]; then
  echo "✅ تم الرفع بنجاح! سيبدأ GitHub Actions الآن ببناء ملف الـ APK تلقائياً."
else
  echo "❌ حدث خطأ أثناء الرفع. تأكد من صلاحية التوكن أو اتصال الإنترنت."
fi
