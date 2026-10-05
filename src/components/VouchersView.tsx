import React, { useState } from 'react';
import { Receipt, Plus, Search, CheckCircle2, Clock } from 'lucide-react';
import { Voucher, Account } from '../types';

interface VouchersViewProps {
  vouchers: Voucher[];
  accounts: Account[];
  onRefresh: () => void;
  onOpenVoucherModal: () => void;
  onShowToast: (msg: string, type?: 'success' | 'error' | 'info') => void;
}

export const VouchersView: React.FC<VouchersViewProps> = ({
  vouchers,
  accounts,
  onRefresh,
  onOpenVoucherModal,
  onShowToast,
}) => {
  const [kindFilter, setKindFilter] = useState('all');

  const filtered = vouchers.filter((v) => {
    return kindFilter === 'all' || v.kind === kindFilter;
  });

  const getKindLabel = (kind: string) => {
    switch (kind) {
      case 'receipt':
        return { label: 'سند قبض', color: 'bg-emerald-50 text-emerald-700 border-emerald-200' };
      case 'payment':
        return { label: 'سند صرف', color: 'bg-rose-50 text-rose-700 border-rose-200' };
      case 'debit':
        return { label: 'قيد مدين', color: 'bg-sky-50 text-sky-700 border-sky-200' };
      case 'credit':
        return { label: 'قيد دائن', color: 'bg-amber-50 text-amber-700 border-amber-200' };
      case 'transfer':
        return { label: 'تحويل', color: 'bg-indigo-50 text-indigo-700 border-indigo-200' };
      default:
        return { label: kind, color: 'bg-slate-100 text-slate-700 border-slate-200' };
    }
  };

  return (
    <div className="space-y-4">
      <div className="bg-white rounded-2xl p-4 border border-slate-200 shadow-xs flex items-center justify-between gap-3">
        <div className="flex items-center gap-2 overflow-x-auto">
          <button
            onClick={() => setKindFilter('all')}
            className={`px-3 py-1.5 rounded-xl text-xs font-bold transition-colors ${
              kindFilter === 'all'
                ? 'bg-sky-600 text-white shadow-xs'
                : 'bg-slate-100 text-slate-600 hover:bg-slate-200'
            }`}
          >
            جميع السندات ({vouchers.length})
          </button>
          <button
            onClick={() => setKindFilter('receipt')}
            className={`px-3 py-1.5 rounded-xl text-xs font-bold transition-colors ${
              kindFilter === 'receipt'
                ? 'bg-sky-600 text-white shadow-xs'
                : 'bg-slate-100 text-slate-600 hover:bg-slate-200'
            }`}
          >
            سندات قبض ({vouchers.filter((v) => v.kind === 'receipt').length})
          </button>
          <button
            onClick={() => setKindFilter('payment')}
            className={`px-3 py-1.5 rounded-xl text-xs font-bold transition-colors ${
              kindFilter === 'payment'
                ? 'bg-sky-600 text-white shadow-xs'
                : 'bg-slate-100 text-slate-600 hover:bg-slate-200'
            }`}
          >
            سندات صرف ({vouchers.filter((v) => v.kind === 'payment').length})
          </button>
        </div>

        <button
          onClick={onOpenVoucherModal}
          className="flex items-center gap-1.5 px-3.5 py-2 text-xs font-bold bg-sky-600 hover:bg-sky-700 text-white rounded-xl shadow-xs transition-colors shrink-0"
        >
          <Plus className="w-4 h-4" />
          <span>سند جديد</span>
        </button>
      </div>

      <div className="bg-white rounded-2xl border border-slate-200 shadow-xs overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-right text-xs">
            <thead className="bg-slate-50/80 border-b border-slate-200 text-slate-500 font-bold">
              <tr>
                <th className="py-3.5 px-4">رقم السند والنوع</th>
                <th className="py-3.5 px-4">الحساب المستفيد / الدافع</th>
                <th className="py-3.5 px-4">المبلغ</th>
                <th className="py-3.5 px-4">البيان</th>
                <th className="py-3.5 px-4">التاريخ والحالة</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {filtered.length === 0 ? (
                <tr>
                  <td colSpan={5} className="py-12 text-center text-slate-400">
                    لا توجد سندات مسجلة
                  </td>
                </tr>
              ) : (
                filtered.map((v) => {
                  const badge = getKindLabel(v.kind);
                  return (
                    <tr key={v.id} className="hover:bg-slate-50/70 transition-colors">
                      <td className="py-3.5 px-4">
                        <div className="flex items-center gap-2">
                          <span className="font-mono font-bold text-slate-900">{v.number}</span>
                          <span className={`text-[10px] px-2 py-0.5 rounded-full font-bold border ${badge.color}`}>
                            {badge.label}
                          </span>
                        </div>
                      </td>

                      <td className="py-3.5 px-4 font-bold text-slate-800">
                        {v.account_name || 'حساب نقدي عام'}
                      </td>

                      <td className="py-3.5 px-4 font-mono font-black text-slate-900">
                        {v.amount} {v.currency}
                      </td>

                      <td className="py-3.5 px-4 text-slate-600 max-w-xs truncate">
                        {v.statement || '-'}
                      </td>

                      <td className="py-3.5 px-4">
                        <div className="flex items-center gap-1.5 text-slate-500 text-[11px] font-mono">
                          <Clock className="w-3 h-3 text-slate-400" />
                          <span>{new Date(v.date).toLocaleDateString('ar-YE')}</span>
                          <span className="text-[10px] px-2 py-0.5 rounded-md bg-emerald-50 text-emerald-700 font-bold">
                            معتمد
                          </span>
                        </div>
                      </td>
                    </tr>
                  );
                })
              )}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
};
