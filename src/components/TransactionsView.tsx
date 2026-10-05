import React, { useState } from 'react';
import {
  CreditCard,
  Plus,
  ArrowDownLeft,
  ArrowUpRight,
  Search,
  Trash2,
  Calendar,
  Tag,
} from 'lucide-react';
import { Transaction, Account } from '../types';
import { api } from '../api';
import { ConfirmModal } from './ConfirmModal';
import { usePermissions } from '../hooks/usePermissions';

interface TransactionsViewProps {
  transactions: Transaction[];
  accounts: Account[];
  onRefresh: () => void;
  onOpenTxModal: () => void;
  onShowToast: (msg: string, type?: 'success' | 'error' | 'info') => void;
}

export const TransactionsView: React.FC<TransactionsViewProps> = ({
  transactions,
  accounts,
  onRefresh,
  onOpenTxModal,
  onShowToast,
}) => {
  const [typeFilter, setTypeFilter] = useState<string>('all');
  const [accountFilter, setAccountFilter] = useState<string>('all');
  const [search, setSearch] = useState<string>('');
  const [deleteTxId, setDeleteTxId] = useState<number | null>(null);
  const [isDeleting, setIsDeleting] = useState(false);

  const { canDeleteTx } = usePermissions();

  const filtered = transactions.filter((tx) => {
    const matchesType = typeFilter === 'all' || tx.type === typeFilter;
    const matchesAccount = accountFilter === 'all' || String(tx.account_id) === accountFilter;
    const matchesSearch =
      (tx.account_name && tx.account_name.toLowerCase().includes(search.toLowerCase())) ||
      (tx.description && tx.description.toLowerCase().includes(search.toLowerCase())) ||
      (tx.reference && tx.reference.toLowerCase().includes(search.toLowerCase()));
    return matchesType && matchesAccount && matchesSearch;
  });

  const handleConfirmDelete = async () => {
    if (!deleteTxId || !canDeleteTx) return;
    setIsDeleting(true);
    try {
      await api.deleteTransaction(deleteTxId);
      onShowToast('تم حذف العملية المالية بنجاح', 'success');
      setDeleteTxId(null);
      onRefresh();
    } catch (err: any) {
      onShowToast(err.message || 'فشل حذف العملية', 'error');
    } finally {
      setIsDeleting(false);
    }
  };

  const formatMoney = (val: number, cur = 'ر.ي') => {
    return `${new Intl.NumberFormat('ar-YE').format(Math.round(val || 0))} ${cur}`;
  };

  const getTypeBadge = (type: string) => {
    switch (type) {
      case 'debit':
        return { label: 'عليه (مدين)', class: 'bg-rose-50 text-rose-700 border-rose-200' };
      case 'credit':
        return { label: 'له (دائن)', class: 'bg-emerald-50 text-emerald-700 border-emerald-200' };
      case 'inflow':
        return { label: 'سند قبض', class: 'bg-sky-50 text-sky-700 border-sky-200' };
      case 'outflow':
        return { label: 'سند صرف', class: 'bg-amber-50 text-amber-700 border-amber-200' };
      case 'revenue':
        return { label: 'إيراد', class: 'bg-teal-50 text-teal-700 border-teal-200' };
      case 'expense':
        return { label: 'مصروف', class: 'bg-orange-50 text-orange-700 border-orange-200' };
      default:
        return { label: type, class: 'bg-slate-100 text-slate-700 border-slate-200' };
    }
  };

  return (
    <div className="space-y-4">
      {/* Controls bar */}
      <div className="bg-white rounded-2xl p-4 border border-slate-200 shadow-xs flex flex-col md:flex-row md:items-center justify-between gap-3">
        <div className="flex flex-wrap items-center gap-2">
          {/* Type filter */}
          <select
            id="select-tx-type-filter"
            value={typeFilter}
            onChange={(e) => setTypeFilter(e.target.value)}
            className="py-1.5 px-3 bg-slate-50 border border-slate-200 rounded-xl text-xs font-bold text-slate-700 focus:bg-white focus:outline-hidden"
          >
            <option value="all">جميع أنواع العمليات</option>
            <option value="debit">عليه (مدين) 🔴</option>
            <option value="credit">له (دائن) 🟢</option>
            <option value="inflow">سند قبض 💵</option>
            <option value="outflow">سند صرف 💸</option>
            <option value="revenue">إيراد 📈</option>
            <option value="expense">مصروف 📉</option>
          </select>

          {/* Account filter */}
          <select
            id="select-tx-account-filter"
            value={accountFilter}
            onChange={(e) => setAccountFilter(e.target.value)}
            className="py-1.5 px-3 bg-slate-50 border border-slate-200 rounded-xl text-xs font-medium text-slate-700 focus:bg-white focus:outline-hidden max-w-[180px]"
          >
            <option value="all">كافة الحسابات</option>
            {accounts.map((acc) => (
              <option key={acc.id} value={acc.id}>
                {acc.name}
              </option>
            ))}
          </select>
        </div>

        <div className="flex items-center gap-2">
          <div className="relative flex-1 md:w-56">
            <Search className="w-4 h-4 absolute right-3 top-3 text-slate-400" />
            <input
              type="text"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="بحث بالبيان أو المرجع..."
              className="w-full pr-9 pl-3 py-2 bg-slate-50 border border-slate-200 rounded-xl text-xs focus:bg-white focus:outline-hidden"
            />
          </div>

          <button
            id="btn-add-tx-view"
            onClick={onOpenTxModal}
            className="flex items-center gap-1.5 px-3.5 py-2 text-xs font-bold bg-sky-600 hover:bg-sky-700 text-white rounded-xl shadow-xs transition-colors shrink-0"
          >
            <Plus className="w-4 h-4" />
            <span>عملية جديدة</span>
          </button>
        </div>
      </div>

      {/* Transactions list */}
      <div className="bg-white rounded-2xl border border-slate-200 shadow-xs overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-right text-xs">
            <thead className="bg-slate-50/80 border-b border-slate-200 text-slate-500 font-bold">
              <tr>
                <th className="py-3.5 px-4">النوع والبيان</th>
                <th className="py-3.5 px-4">الحساب</th>
                <th className="py-3.5 px-4">المبلغ</th>
                <th className="py-3.5 px-4">التاريخ والمرجع</th>
                <th className="py-3.5 px-4 text-left">إجراءات</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {filtered.length === 0 ? (
                <tr>
                  <td colSpan={5} className="py-12 text-center text-slate-400">
                    لا توجد عمليات مسجلة مطابقة للفلاتر
                  </td>
                </tr>
              ) : (
                filtered.map((tx) => {
                  const badge = getTypeBadge(tx.type);
                  return (
                    <tr key={tx.id} className="hover:bg-slate-50/70 transition-colors">
                      {/* Type & Description */}
                      <td className="py-3.5 px-4">
                        <div className="flex items-center gap-3">
                          <div className="w-8 h-8 rounded-xl bg-slate-100 flex items-center justify-center shrink-0">
                            {tx.type === 'debit' ? (
                              <ArrowDownLeft className="w-4 h-4 text-rose-600" />
                            ) : (
                              <ArrowUpRight className="w-4 h-4 text-emerald-600" />
                            )}
                          </div>
                          <div>
                            <div className="flex items-center gap-1.5">
                              <span className={`text-[10px] px-2 py-0.5 rounded-full font-bold border ${badge.class}`}>
                                {badge.label}
                              </span>
                            </div>
                            <p className="text-xs font-semibold text-slate-800 mt-1">
                              {tx.description || 'عملية مالية'}
                            </p>
                          </div>
                        </div>
                      </td>

                      {/* Account */}
                      <td className="py-3.5 px-4">
                        <span className="font-bold text-slate-800">
                          {tx.account_name || 'حساب عام'}
                        </span>
                      </td>

                      {/* Amount */}
                      <td className="py-3.5 px-4 font-mono">
                        <span className="text-xs font-black text-slate-900">
                          {formatMoney(tx.amount, tx.currency)}
                        </span>
                      </td>

                      {/* Date & Ref */}
                      <td className="py-3.5 px-4 text-slate-500">
                        <div className="text-[11px] font-mono">
                          {new Date(tx.date).toLocaleDateString('ar-YE')}
                        </div>
                        {tx.reference && (
                          <div className="text-[10px] text-slate-400 font-mono">
                            مرجع: #{tx.reference}
                          </div>
                        )}
                      </td>

                      {/* Action */}
                      <td className="py-3.5 px-4 text-left">
                        {canDeleteTx && (
                          <button
                            id={`btn-delete-tx-${tx.id}`}
                            onClick={() => setDeleteTxId(tx.id)}
                            className="p-1.5 rounded-lg text-slate-400 hover:text-rose-600 hover:bg-rose-50 transition-colors"
                            title="حذف العملية"
                          >
                            <Trash2 className="w-3.5 h-3.5" />
                          </button>
                        )}
                      </td>
                    </tr>
                  );
                })
              )}
            </tbody>
          </table>
        </div>
      </div>

      {/* Confirm Delete Modal */}
      <ConfirmModal
        isOpen={deleteTxId !== null}
        title="تأكيد حذف العملية المالية"
        message="هل أنت متأكد من رغبتك في حذف هذه الحركة المالية؟ سيتم عكس تأثيرها على رصيد الحساب تلقائياً."
        confirmLabel="حذف العملية"
        cancelLabel="تراجع"
        variant="danger"
        isLoading={isDeleting}
        onConfirm={handleConfirmDelete}
        onCancel={() => setDeleteTxId(null)}
      />
    </div>
  );
};
