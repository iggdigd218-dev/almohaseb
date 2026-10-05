import React, { useState } from 'react';
import { Building2, User, Check, ArrowLeft, Shield, Sparkles, Store } from 'lucide-react';

interface WorkspaceModeModalProps {
  isOpen: boolean;
  userName?: string;
  userEmail?: string;
  initialMode?: 'enterprise' | 'individual';
  initialStoreId?: string;
  onConfirm: (mode: 'enterprise' | 'individual', storeId: string) => Promise<void> | void;
  isLoading?: boolean;
}

export const WorkspaceModeModal: React.FC<WorkspaceModeModalProps> = ({
  isOpen,
  userName,
  userEmail,
  initialMode = 'enterprise',
  initialStoreId = 'store-main',
  onConfirm,
  isLoading = false,
}) => {
  const [selectedMode, setSelectedMode] = useState<'enterprise' | 'individual'>(initialMode);
  const [storeId, setStoreId] = useState(initialStoreId);
  const [submitting, setSubmitting] = useState(false);

  if (!isOpen) return null;

  const handleConfirm = async () => {
    setSubmitting(true);
    try {
      const finalStoreId = selectedMode === 'enterprise' ? (storeId.trim() || 'store-main') : 'store-local';
      await onConfirm(selectedMode, finalStoreId);
    } finally {
      setSubmitting(false);
    }
  };

  const displayName = userName || (userEmail ? userEmail.split('@')[0] : 'المدير');

  return (
    <div className="fixed inset-0 bg-slate-900/70 backdrop-blur-xs flex items-center justify-center p-4 z-50 animate-in fade-in" dir="rtl">
      <div className="bg-white rounded-3xl p-6 sm:p-7 max-w-lg w-full border border-slate-200 shadow-2xl space-y-5 animate-in zoom-in-95">
        {/* Header */}
        <div className="text-center space-y-1.5">
          <div className="w-13 h-13 rounded-2xl bg-indigo-50 text-indigo-600 flex items-center justify-center mx-auto text-xl font-bold border border-indigo-100 shadow-xs">
            <Sparkles className="w-7 h-7 text-indigo-600" />
          </div>
          <h2 className="text-lg font-black text-slate-900">
            مرحباً بك {displayName}! اختر نمط العمل
          </h2>
          <p className="text-xs text-slate-500 max-w-sm mx-auto">
            تم تسجيل دخولك بنجاح. حدد الآن طبيعة مساحة العمل التي تناسب نشاطك للبدء:
          </p>
        </div>

        {/* Mode Cards */}
        <div className="grid grid-cols-1 gap-3">
          {/* Enterprise Mode Option */}
          <div
            onClick={() => setSelectedMode('enterprise')}
            className={`p-4 rounded-2xl border-2 transition-all cursor-pointer relative text-right flex flex-col gap-2 ${
              selectedMode === 'enterprise'
                ? 'border-indigo-600 bg-indigo-50/50 shadow-md ring-1 ring-indigo-600/20'
                : 'border-slate-200 hover:border-slate-300 hover:bg-slate-50/60 bg-white'
            }`}
          >
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-2.5">
                <div
                  className={`w-10 h-10 rounded-xl flex items-center justify-center font-bold ${
                    selectedMode === 'enterprise'
                      ? 'bg-indigo-600 text-white shadow-xs'
                      : 'bg-slate-100 text-slate-600'
                  }`}
                >
                  <Building2 className="w-5 h-5" />
                </div>
                <div>
                  <h3 className="font-extrabold text-sm text-slate-900 flex items-center gap-1.5">
                    <span>منشأة / مؤسسة تجارية</span>
                    <span className="text-[10px] px-2 py-0.5 rounded-full bg-indigo-100 text-indigo-700 font-bold">
                      تعدد أجهزة ومزامنة
                    </span>
                  </h3>
                  <p className="text-[11px] text-slate-500 mt-0.5">
                    متاجر، شركات، فروع، وتجارة جملة وتجزئة
                  </p>
                </div>
              </div>
              <div
                className={`w-5 h-5 rounded-full border-2 flex items-center justify-center shrink-0 ${
                  selectedMode === 'enterprise'
                    ? 'border-indigo-600 bg-indigo-600 text-white'
                    : 'border-slate-300'
                }`}
              >
                {selectedMode === 'enterprise' && <Check className="w-3.5 h-3.5 stroke-[3]" />}
              </div>
            </div>

            <ul className="text-[11px] text-slate-600 space-y-1 pr-1 border-t border-slate-100/80 pt-2 mt-1">
              <li className="flex items-center gap-1.5">
                <span className="w-1.5 h-1.5 rounded-full bg-indigo-600"></span>
                <span>ربط كاشيرات متعددة وأجهزة محاسبة وإدارة متزامنة</span>
              </li>
              <li className="flex items-center gap-1.5">
                <span className="w-1.5 h-1.5 rounded-full bg-indigo-600"></span>
                <span>مزامنة سحابية لحظية بين الأجهزة والفروع</span>
              </li>
            </ul>

            {selectedMode === 'enterprise' && (
              <div className="pt-2 border-t border-indigo-100/70 mt-1" onClick={(e) => e.stopPropagation()}>
                <label className="text-[11px] font-bold text-slate-700 block mb-1">
                  معرّف مساحة المنشأة (Store ID):
                </label>
                <div className="relative">
                  <input
                    type="text"
                    dir="ltr"
                    value={storeId}
                    onChange={(e) => setStoreId(e.target.value)}
                    placeholder="store-main"
                    className="w-full px-3 py-1.5 pl-8 bg-white border border-indigo-200 rounded-xl focus:outline-hidden text-slate-900 font-mono text-xs text-left"
                  />
                  <Store className="w-4 h-4 text-indigo-400 absolute left-2.5 top-2 pointer-events-none" />
                </div>
              </div>
            )}
          </div>

          {/* Individual Mode Option */}
          <div
            onClick={() => setSelectedMode('individual')}
            className={`p-4 rounded-2xl border-2 transition-all cursor-pointer relative text-right flex flex-col gap-2 ${
              selectedMode === 'individual'
                ? 'border-emerald-600 bg-emerald-50/50 shadow-md ring-1 ring-emerald-600/20'
                : 'border-slate-200 hover:border-slate-300 hover:bg-slate-50/60 bg-white'
            }`}
          >
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-2.5">
                <div
                  className={`w-10 h-10 rounded-xl flex items-center justify-center font-bold ${
                    selectedMode === 'individual'
                      ? 'bg-emerald-600 text-white shadow-xs'
                      : 'bg-slate-100 text-slate-600'
                  }`}
                >
                  <User className="w-5 h-5" />
                </div>
                <div>
                  <h3 className="font-extrabold text-sm text-slate-900 flex items-center gap-1.5">
                    <span>نشاط فردي مستقل</span>
                    <span className="text-[10px] px-2 py-0.5 rounded-full bg-emerald-100 text-emerald-700 font-bold">
                      بساطة وسرعة فائقة
                    </span>
                  </h3>
                  <p className="text-[11px] text-slate-500 mt-0.5">
                    حسابات شخصية، ديون ومستحقات، أو نشاط تجاري فردي
                  </p>
                </div>
              </div>
              <div
                className={`w-5 h-5 rounded-full border-2 flex items-center justify-center shrink-0 ${
                  selectedMode === 'individual'
                    ? 'border-emerald-600 bg-emerald-600 text-white'
                    : 'border-slate-300'
                }`}
              >
                {selectedMode === 'individual' && <Check className="w-3.5 h-3.5 stroke-[3]" />}
              </div>
            </div>

            <ul className="text-[11px] text-slate-600 space-y-1 pr-1 border-t border-slate-100/80 pt-2 mt-1">
              <li className="flex items-center gap-1.5">
                <span className="w-1.5 h-1.5 rounded-full bg-emerald-600"></span>
                <span>تشغيل مستقل بالكامل على هذا الجهاز دون تعقيدات ربط الأجهزة</span>
              </li>
              <li className="flex items-center gap-1.5">
                <span className="w-1.5 h-1.5 rounded-full bg-emerald-600"></span>
                <span>خصوصية وسرعة مع حفظ محلي كامل لقاعدة البيانات</span>
              </li>
            </ul>
          </div>
        </div>

        {/* Sovereign Admin Assurance */}
        <div className="p-2.5 rounded-xl bg-slate-50 border border-slate-200 text-slate-600 flex items-center gap-2 text-[11px]">
          <Shield className="w-4 h-4 text-indigo-600 shrink-0" />
          <span>يمكنك في أي وقت لاحق تغيير هذا النمط بسهولة من شاشة الإعدادات.</span>
        </div>

        {/* Submit Button */}
        <div className="pt-1">
          <button
            type="button"
            onClick={handleConfirm}
            disabled={submitting || isLoading}
            className="w-full py-3 px-5 rounded-2xl bg-indigo-600 hover:bg-indigo-700 active:scale-98 text-white font-extrabold shadow-lg shadow-indigo-600/30 transition-all flex items-center justify-center gap-2 text-sm disabled:opacity-50"
          >
            {submitting || isLoading ? (
              <span>جارٍ التهيئة والحفظ...</span>
            ) : (
              <>
                <span>تأكيد وبدء العمل في النظام</span>
                <ArrowLeft className="w-4 h-4" />
              </>
            )}
          </button>
        </div>
      </div>
    </div>
  );
};
