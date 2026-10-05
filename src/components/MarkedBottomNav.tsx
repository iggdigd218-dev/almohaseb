import React from 'react';
import {
  Users,
  CreditCard,
  Plus,
  BarChart3,
  Settings,
  ShoppingCart,
} from 'lucide-react';
import { usePermissions } from '../hooks/usePermissions';

interface MarkedBottomNavProps {
  currentScreen: string;
  onSelectScreen: (screen: string) => void;
  onOpenTxModal: () => void;
}

export const MarkedBottomNav: React.FC<MarkedBottomNavProps> = ({
  currentScreen,
  onSelectScreen,
  onOpenTxModal,
}) => {
  const { canViewReports } = usePermissions();
  return (
    <div className="fixed bottom-0 inset-x-0 z-40 bg-white/95 backdrop-blur-md border-t border-slate-200/80 shadow-[0_-4px_20px_rgba(0,0,0,0.06)] px-2 py-1.5 md:hidden">
      <div className="flex items-center justify-around max-w-lg mx-auto relative">
        {/* الحسابات والعملاء */}
        <button
          onClick={() => onSelectScreen('accounts')}
          className={`flex flex-col items-center justify-center py-1 px-2.5 rounded-2xl transition-all duration-200 min-w-[58px] ${
            currentScreen === 'accounts'
              ? 'text-sky-600 bg-sky-50/80 font-bold scale-105 shadow-xs'
              : 'text-slate-500 hover:text-slate-800'
          }`}
        >
          <div className="relative">
            <Users className={`w-5 h-5 ${currentScreen === 'accounts' ? 'stroke-[2.5]' : 'stroke-2'}`} />
            {currentScreen === 'accounts' && (
              <span className="absolute -bottom-1 left-1/2 -translate-x-1/2 w-1.5 h-1.5 bg-sky-600 rounded-full"></span>
            )}
          </div>
          <span className="text-[11px] mt-1 tracking-tight font-medium">العملاء</span>
        </button>

        {/* الحركات والعمليات */}
        <button
          onClick={() => onSelectScreen('transactions')}
          className={`flex flex-col items-center justify-center py-1 px-2.5 rounded-2xl transition-all duration-200 min-w-[58px] ${
            currentScreen === 'transactions'
              ? 'text-sky-600 bg-sky-50/80 font-bold scale-105 shadow-xs'
              : 'text-slate-500 hover:text-slate-800'
          }`}
        >
          <div className="relative">
            <CreditCard className={`w-5 h-5 ${currentScreen === 'transactions' ? 'stroke-[2.5]' : 'stroke-2'}`} />
            {currentScreen === 'transactions' && (
              <span className="absolute -bottom-1 left-1/2 -translate-x-1/2 w-1.5 h-1.5 bg-sky-600 rounded-full"></span>
            )}
          </div>
          <span className="text-[11px] mt-1 tracking-tight font-medium">الحركات</span>
        </button>

        {/* الزر المركزي المعلم للعمليات (+ عملية) */}
        <div className="relative -top-3 flex flex-col items-center">
          <button
            onClick={onOpenTxModal}
            className="w-13 h-13 rounded-full bg-gradient-to-tr from-sky-600 via-sky-500 to-indigo-600 text-white flex items-center justify-center shadow-lg shadow-sky-500/40 hover:scale-105 active:scale-95 transition-transform duration-150 border-2 border-white"
            title="تسجيل عملية جديدة"
          >
            <Plus className="w-6 h-6 stroke-[2.8]" />
          </button>
          <span className="text-[10.5px] font-bold text-sky-700 mt-0.5">عملية</span>
        </div>

        {/* التقارير أو نقطة البيع حسب الصلاحية */}
        {canViewReports ? (
          <button
            onClick={() => onSelectScreen('reports')}
            className={`flex flex-col items-center justify-center py-1 px-2.5 rounded-2xl transition-all duration-200 min-w-[58px] ${
              currentScreen === 'reports'
                ? 'text-sky-600 bg-sky-50/80 font-bold scale-105 shadow-xs'
                : 'text-slate-500 hover:text-slate-800'
            }`}
          >
            <div className="relative flex items-end justify-center gap-0.5 h-5 w-5 pt-0.5">
              <span className="w-1 h-2.5 bg-emerald-500 rounded-t-xs"></span>
              <span className="w-1 h-4 bg-amber-500 rounded-t-xs"></span>
              <span className="w-1 h-3 bg-sky-500 rounded-t-xs"></span>
              {currentScreen === 'reports' && (
                <span className="absolute -bottom-1.5 left-1/2 -translate-x-1/2 w-1.5 h-1.5 bg-sky-600 rounded-full"></span>
              )}
            </div>
            <span className="text-[11px] mt-1 tracking-tight font-medium">التقارير</span>
          </button>
        ) : (
          <button
            onClick={() => onSelectScreen('pos')}
            className={`flex flex-col items-center justify-center py-1 px-2.5 rounded-2xl transition-all duration-200 min-w-[58px] ${
              currentScreen === 'pos'
                ? 'text-sky-600 bg-sky-50/80 font-bold scale-105 shadow-xs'
                : 'text-slate-500 hover:text-slate-800'
            }`}
          >
            <div className="relative">
              <ShoppingCart className={`w-5 h-5 ${currentScreen === 'pos' ? 'stroke-[2.5]' : 'stroke-2'}`} />
              {currentScreen === 'pos' && (
                <span className="absolute -bottom-1 left-1/2 -translate-x-1/2 w-1.5 h-1.5 bg-sky-600 rounded-full"></span>
              )}
            </div>
            <span className="text-[11px] mt-1 tracking-tight font-medium">نقطة البيع</span>
          </button>
        )}

        {/* الإشعارات أو الإعدادات */}
        <button
          onClick={() => onSelectScreen('settings')}
          className={`flex flex-col items-center justify-center py-1 px-2.5 rounded-2xl transition-all duration-200 min-w-[58px] ${
            currentScreen === 'settings'
              ? 'text-sky-600 bg-sky-50/80 font-bold scale-105 shadow-xs'
              : 'text-slate-500 hover:text-slate-800'
          }`}
        >
          <div className="relative">
            <Settings className={`w-5 h-5 ${currentScreen === 'settings' ? 'stroke-[2.5]' : 'stroke-2'}`} />
            {currentScreen === 'settings' && (
              <span className="absolute -bottom-1 left-1/2 -translate-x-1/2 w-1.5 h-1.5 bg-sky-600 rounded-full"></span>
            )}
          </div>
          <span className="text-[11px] mt-1 tracking-tight font-medium">الإعدادات</span>
        </button>
      </div>
    </div>
  );
};
