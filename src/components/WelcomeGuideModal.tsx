import React from 'react';
import {
  BookOpen,
  ShoppingCart,
  Users,
  Network,
  Database,
  CheckCircle2,
  X,
  ArrowLeft,
  Sparkles,
  Smartphone,
  ShieldCheck,
} from 'lucide-react';

interface WelcomeGuideModalProps {
  isOpen: boolean;
  onClose: () => void;
  onNavigate: (screen: string) => void;
}

export const WelcomeGuideModal: React.FC<WelcomeGuideModalProps> = ({
  isOpen,
  onClose,
  onNavigate,
}) => {
  if (!isOpen) return null;

  const features = [
    {
      icon: ShoppingCart,
      color: 'bg-emerald-100 text-emerald-700',
      title: 'نقطة البيع وإصدار الفواتير (POS)',
      desc: 'إصدار فواتير نقدية وآجلة سريعة، خصومات، واختيار العميل، مع دعم إرسال الفاتورة الفورية عبر واتساب أو الطباعة.',
      screen: 'pos',
      buttonText: 'فتح نقطة البيع',
    },
    {
      icon: Users,
      color: 'bg-sky-100 text-sky-700',
      title: 'سجل الحسابات والديون وكشف الحساب',
      desc: 'إدارة شاملة لعملاء وموردي المنشأة، تتبع الذمم والديون بدقة، وكشف حساب تفصيلي تفاعلي مع زر مشاركة عبر واتساب.',
      screen: 'accounts',
      buttonText: 'إدارة الحسابات',
    },
    {
      icon: Network,
      color: 'bg-amber-100 text-amber-700',
      title: 'ربط الأجهزة والمزامنة الفورية (SSE)',
      desc: 'ربط أجهزة الموظفين بنظام الدعوات المؤقتة (PIN / QR Code)، ومزامنة حية لحظية للعمليات والحسابات بين المدير والأعضاء.',
      screen: 'group',
      buttonText: 'ربط الأجهزة',
    },
    {
      icon: Database,
      color: 'bg-purple-100 text-purple-700',
      title: 'النسخ الاحتياطي والاستعادة الشاملة',
      desc: 'حفظ آمن للبيانات في قاعدة SQLite، مع إمكانية تصدير واسترجاع نسخة كاملة من ملفات JSON في أي وقت.',
      screen: 'backup',
      buttonText: 'النسخ الاحتياطي',
    },
  ];

  return (
    <div className="fixed inset-0 bg-slate-900/60 backdrop-blur-xs flex items-center justify-center p-4 z-50 animate-in fade-in duration-200">
      <div className="bg-white rounded-3xl p-6 max-w-xl w-full border border-slate-200 shadow-2xl space-y-5 max-h-[90vh] overflow-y-auto text-right">
        {/* Header */}
        <div className="flex items-start justify-between pb-3 border-b border-slate-100">
          <div className="flex items-center gap-3">
            <div className="w-12 h-12 rounded-2xl bg-gradient-to-tr from-sky-500 to-indigo-600 text-white flex items-center justify-center text-xl shadow-lg shadow-sky-500/20 font-bold">
              📒
            </div>
            <div>
              <div className="flex items-center gap-1.5">
                <h2 className="font-black text-base text-slate-900">سجل المبيعات والديون - Nexora</h2>
                <span className="px-2 py-0.5 rounded-full text-[10px] font-bold bg-sky-50 text-sky-700 border border-sky-200">
                  دليل الاستخدام السريع
                </span>
              </div>
              <p className="text-xs text-slate-500 mt-0.5">
                نظامك المحاسبي المتكامل لإدارة المبيعات والديون والمخزون والمزامنة بين الأجهزة
              </p>
            </div>
          </div>
          <button
            onClick={onClose}
            className="p-1.5 rounded-xl text-slate-400 hover:text-slate-600 hover:bg-slate-100 transition-colors"
          >
            <X className="w-5 h-5" />
          </button>
        </div>

        {/* Feature List */}
        <div className="space-y-3">
          {features.map((feat, idx) => {
            const Icon = feat.icon;
            return (
              <div
                key={idx}
                className="p-3.5 rounded-2xl border border-slate-100 bg-slate-50/70 hover:bg-slate-50 hover:border-slate-200 transition-all flex flex-col sm:flex-row sm:items-center justify-between gap-3"
              >
                <div className="flex items-start gap-3">
                  <div className={`w-10 h-10 rounded-xl ${feat.color} flex items-center justify-center shrink-0 mt-0.5`}>
                    <Icon className="w-5 h-5" />
                  </div>
                  <div>
                    <h4 className="font-extrabold text-xs text-slate-900">{feat.title}</h4>
                    <p className="text-[11px] text-slate-500 mt-0.5 leading-relaxed">{feat.desc}</p>
                  </div>
                </div>

                <button
                  onClick={() => {
                    onNavigate(feat.screen);
                    onClose();
                  }}
                  className="px-3 py-1.5 rounded-xl bg-white hover:bg-slate-100 border border-slate-200 text-slate-700 text-xs font-bold shrink-0 flex items-center justify-center gap-1 shadow-2xs transition-colors self-end sm:self-center"
                >
                  <span>{feat.buttonText}</span>
                  <ArrowLeft className="w-3.5 h-3.5" />
                </button>
              </div>
            );
          })}
        </div>

        {/* Pro Tip */}
        <div className="p-3 bg-emerald-50 border border-emerald-200/80 rounded-2xl flex items-center gap-2.5 text-xs text-emerald-800">
          <ShieldCheck className="w-4 h-4 text-emerald-600 shrink-0" />
          <p className="leading-relaxed text-[11px]">
            <span className="font-bold">ملاحظة أمان:</span> البيانات محفوظة محلياً بنظام SQLite فائق السرعة، ومزامنة فورية مشفرة بين الأجهزة عبر بروتوكول SSE ورمز PIN.
          </p>
        </div>

        {/* Footer */}
        <div className="pt-2 flex justify-end">
          <button
            onClick={onClose}
            className="w-full sm:w-auto px-6 py-2.5 rounded-xl bg-sky-600 hover:bg-sky-700 text-white text-xs font-black shadow-xs transition-colors"
          >
            بدء استخدام النظام الآن
          </button>
        </div>
      </div>
    </div>
  );
};
