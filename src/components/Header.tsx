import React, { useState, useEffect } from 'react';
import { Plus, RefreshCw, UserPlus, HelpCircle, Type, Menu, Shield } from 'lucide-react';
import { SyncArrowsIndicator } from './SyncArrowsIndicator';

interface HeaderProps {
  title: string;
  onRefresh: () => void;
  onOpenTxModal: () => void;
  onOpenAccountModal: () => void;
  onOpenHelpGuide?: () => void;
  onOpenMobileMenu?: () => void;
  onOpenLogin?: () => void;
  isLoading?: boolean;
  onShowToast?: (msg: string, type?: 'success' | 'error' | 'info') => void;
}

export const Header: React.FC<HeaderProps> = ({
  title,
  onRefresh,
  onOpenTxModal,
  onOpenAccountModal,
  onOpenHelpGuide,
  onOpenMobileMenu,
  onOpenLogin,
  isLoading,
  onShowToast,
}) => {
  const [currentFont, setCurrentFont] = useState<string>(() => {
    return localStorage.getItem('app-font') || 'naskh';
  });

  const [isFontMenuOpen, setIsFontMenuOpen] = useState(false);

  useEffect(() => {
    document.documentElement.setAttribute('data-font', currentFont);
    localStorage.setItem('app-font', currentFont);
  }, [currentFont]);

  const fontOptions = [
    { id: 'naskh', label: 'خط النسخ (الافتراضي)', sub: 'Noto Naskh' },
    { id: 'amiri', label: 'خط النسخ الأميري', sub: 'Amiri' },
    { id: 'tajawal', label: 'خط النسخ الحديث', sub: 'Tajawal' },
  ];

  return (
    <header className="h-16 bg-white border-b border-slate-200 px-4 sm:px-6 flex items-center justify-between sticky top-0 z-10 shadow-xs">
      <div className="flex items-center gap-2.5">
        {onOpenMobileMenu && (
          <button
            onClick={onOpenMobileMenu}
            className="md:hidden p-2 text-slate-600 hover:text-slate-900 hover:bg-slate-100 rounded-xl transition-colors"
            title="القائمة الجانبية"
          >
            <Menu className="w-5 h-5" />
          </button>
        )}
        <div>
          <h2 className="text-lg font-black text-slate-800 tracking-tight">{title}</h2>
          <div className="flex items-center gap-2 mt-0.5">
            <p className="text-xs text-slate-600 font-medium">سجل المبيعات والديون • نظام محلي متكامل</p>
          </div>
        </div>
      </div>

      <div className="flex items-center gap-2">
        {/* زر تبديل نمط خط النسخ */}
        <div className="relative">
          <button
            onClick={() => setIsFontMenuOpen(!isFontMenuOpen)}
            className="flex items-center gap-1.5 px-2.5 py-1.5 text-xs font-bold text-slate-700 bg-slate-100 hover:bg-slate-200 rounded-xl transition-colors border border-slate-200/60"
            title="تخصيص خط النسخ"
          >
            <Type className="w-3.5 h-3.5 text-sky-600" />
            <span className="text-[11px]">
              {fontOptions.find((f) => f.id === currentFont)?.label.replace(' (الافتراضي)', '') || 'خط النسخ'}
            </span>
          </button>

          {isFontMenuOpen && (
            <div className="absolute left-0 mt-1.5 w-48 bg-white rounded-xl shadow-xl border border-slate-150 py-1.5 z-50 text-right animate-in fade-in zoom-in-95">
              <div className="px-3 py-1 text-[10.5px] font-bold text-slate-400 border-b border-slate-100">
                اختيار خط النسخ للتطبيق:
              </div>
              {fontOptions.map((opt) => (
                <button
                  key={opt.id}
                  onClick={() => {
                    setCurrentFont(opt.id);
                    setIsFontMenuOpen(false);
                  }}
                  className={`w-full text-right px-3 py-2 text-xs flex items-center justify-between transition-colors ${
                    currentFont === opt.id
                      ? 'bg-sky-50 text-sky-700 font-bold'
                      : 'text-slate-700 hover:bg-slate-50'
                  }`}
                >
                  <span>{opt.label}</span>
                  {currentFont === opt.id && <span className="w-1.5 h-1.5 rounded-full bg-sky-600"></span>}
                </button>
              ))}
            </div>
          )}
        </div>

        {onOpenHelpGuide && (
          <button
            id="btn-header-help-guide"
            onClick={onOpenHelpGuide}
            className="hidden sm:flex items-center gap-1.5 px-3 py-2 text-xs font-bold text-sky-700 bg-sky-50 hover:bg-sky-100 rounded-xl transition-colors border border-sky-100"
            title="دليل الاستخدام والترحيب"
          >
            <HelpCircle className="w-4 h-4 text-sky-600" />
            <span>دليل الاستخدام</span>
          </button>
        )}

        {/* مؤشرا المزامنة اللحظية (↑↓) — كما بالنسخة الأصلية للمستودع */}
        <SyncArrowsIndicator onShowToast={onShowToast} />

        {onOpenLogin && (
          <button
            id="btn-header-login"
            onClick={onOpenLogin}
            className="flex items-center gap-1.5 px-3 py-2 text-xs font-bold text-indigo-700 bg-indigo-50 hover:bg-indigo-100 rounded-xl transition-colors border border-indigo-200"
            title="تسجيل الدخول لمنشأة أو حساب فردي (Google أو البريد) واعتماد المدير"
          >
            <Shield className="w-3.5 h-3.5 text-indigo-600" />
            <span className="hidden md:inline">دخول المدير / Google</span>
          </button>
        )}

        <button
          id="btn-header-refresh"
          onClick={onRefresh}
          disabled={isLoading}
          className="p-2 text-slate-600 hover:text-slate-900 bg-slate-100 hover:bg-slate-200 rounded-xl transition-all"
          title="تحديث البيانات"
        >
          <RefreshCw className={`w-4 h-4 ${isLoading ? 'animate-spin text-sky-600' : ''}`} />
        </button>

        <button
          id="btn-header-add-account"
          onClick={onOpenAccountModal}
          className="hidden sm:flex items-center gap-1.5 px-3 py-2 text-xs font-bold text-slate-700 bg-slate-100 hover:bg-slate-200 rounded-xl transition-colors"
        >
          <UserPlus className="w-4 h-4 text-slate-500" />
          <span>حساب جديد</span>
        </button>

        <button
          id="btn-header-add-tx"
          onClick={onOpenTxModal}
          className="flex items-center gap-1.5 px-3.5 sm:px-4 py-2 text-xs font-bold text-white bg-sky-600 hover:bg-sky-700 active:scale-98 rounded-xl shadow-sm shadow-sky-600/30 transition-all"
        >
          <Plus className="w-4 h-4" />
          <span>عملية جديدة</span>
        </button>
      </div>
    </header>
  );
};
