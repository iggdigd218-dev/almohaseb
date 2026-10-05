import React from 'react';
import { BarChart3, TrendingUp, ArrowDownLeft, ArrowUpRight, Package, Printer } from 'lucide-react';
import { DashboardData, Account, Item, Transaction } from '../types';

interface ReportsViewProps {
  dashboard: DashboardData | null;
  accounts: Account[];
  items: Item[];
  transactions: Transaction[];
}

export const ReportsView: React.FC<ReportsViewProps> = ({
  dashboard,
  accounts,
  items,
  transactions,
}) => {
  const formatMoney = (num: number, cur = 'ر.ي') => {
    return `${new Intl.NumberFormat('ar-YE').format(Math.round(num || 0))} ${cur}`;
  };

  const inventoryValuation = items.reduce((acc, it) => acc + it.quantity * it.buy_price, 0);
  const totalDebtorsCount = accounts.filter((a) => (a.balance || 0) > 0).length;
  const totalCreditorsCount = accounts.filter((a) => (a.balance || 0) < 0).length;

  return (
    <div className="space-y-6">
      <div className="bg-white rounded-2xl p-4 border border-slate-200 shadow-xs flex items-center justify-between">
        <div>
          <h3 className="font-extrabold text-sm text-slate-800">التقارير المالية والتحليلية</h3>
          <p className="text-xs text-slate-400">ملخص المركز المالي، حركة المبيعات، ومحفظة الديون</p>
        </div>
        <button
          onClick={() => window.print()}
          className="flex items-center gap-1.5 px-3.5 py-2 text-xs font-bold border border-slate-200 hover:bg-slate-50 text-slate-700 rounded-xl transition-colors"
        >
          <Printer className="w-4 h-4" />
          <span>طباعة التقرير</span>
        </button>
      </div>

      {/* Financial Summary Cards */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        <div className="bg-white rounded-2xl p-4 border border-slate-200 shadow-xs">
          <span className="text-xs font-semibold text-slate-500">إجمالي المبيعات المحققة</span>
          <div className="text-xl font-black text-slate-900 mt-1 font-mono">
            {formatMoney(dashboard?.totalSales || 0)}
          </div>
          <span className="text-[10px] text-slate-400 mt-2 block">صافي الفواتير المقيدة</span>
        </div>

        <div className="bg-white rounded-2xl p-4 border border-slate-200 shadow-xs">
          <span className="text-xs font-semibold text-slate-500">إجمالي الذمم المدينة (لنا)</span>
          <div className="text-xl font-black text-rose-600 mt-1 font-mono">
            {formatMoney(dashboard?.totalDebts || 0)}
          </div>
          <span className="text-[10px] text-slate-400 mt-2 block">{totalDebtorsCount} عميل مدين</span>
        </div>

        <div className="bg-white rounded-2xl p-4 border border-slate-200 shadow-xs">
          <span className="text-xs font-semibold text-slate-500">إجمالي الذمم الدائنة (علينا)</span>
          <div className="text-xl font-black text-emerald-600 mt-1 font-mono">
            {formatMoney(dashboard?.totalCredits || 0)}
          </div>
          <span className="text-[10px] text-slate-400 mt-2 block">{totalCreditorsCount} مورد دائن</span>
        </div>

        <div className="bg-white rounded-2xl p-4 border border-slate-200 shadow-xs">
          <span className="text-xs font-semibold text-slate-500">قيمة المخزون بسعر التكلفة</span>
          <div className="text-xl font-black text-sky-600 mt-1 font-mono">
            {formatMoney(inventoryValuation)}
          </div>
          <span className="text-[10px] text-slate-400 mt-2 block">{items.length} أصناف مسجلة</span>
        </div>
      </div>

      {/* Debtors List Detail */}
      <div className="bg-white rounded-2xl border border-slate-200 shadow-xs overflow-hidden">
        <div className="p-4 border-b border-slate-100 flex items-center justify-between">
          <h4 className="font-extrabold text-sm text-slate-800">تفاصيل الحسابات المدينة (الديون المستحقة)</h4>
          <span className="text-xs font-bold text-slate-500 font-mono">
            {formatMoney(dashboard?.totalDebts || 0)}
          </span>
        </div>

        <div className="divide-y divide-slate-100">
          {accounts
            .filter((a) => (a.balance || 0) > 0)
            .sort((a, b) => (b.balance || 0) - (a.balance || 0))
            .map((acc) => (
              <div key={acc.id} className="p-3.5 flex items-center justify-between">
                <div>
                  <div className="font-bold text-slate-800 text-xs">{acc.name}</div>
                  <div className="text-[11px] text-slate-400">
                    هاتف: {acc.phone || 'غير مسجل'} • فئة: {acc.category || 'عام'}
                  </div>
                </div>

                <div className="text-left font-mono">
                  <div className="text-xs font-black text-rose-600">
                    {formatMoney(acc.balance || 0, acc.currency)}
                  </div>
                </div>
              </div>
            ))}
        </div>
      </div>
    </div>
  );
};
