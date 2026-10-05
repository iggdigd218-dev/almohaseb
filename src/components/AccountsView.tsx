import React, { useState } from 'react';
import {
  Users,
  Search,
  Plus,
  Phone,
  MessageCircle,
  Edit2,
  Trash2,
  Filter,
  DollarSign,
  RefreshCw,
  FileText,
  Send,
  CheckCircle2,
} from 'lucide-react';
import { Account, AccountKind } from '../types';
import { api } from '../api';
import { ConfirmModal } from './ConfirmModal';

interface AccountsViewProps {
  accounts: Account[];
  onRefresh: () => void;
  onOpenAccountModal: (account?: Account) => void;
  onOpenTxModal: (accountId?: number) => void;
  onOpenStatement: (account: Account) => void;
  onShowToast: (msg: string, type?: 'success' | 'error' | 'info') => void;
}

export const AccountsView: React.FC<AccountsViewProps> = ({
  accounts,
  onRefresh,
  onOpenAccountModal,
  onOpenTxModal,
  onOpenStatement,
  onShowToast,
}) => {
  const [kindFilter, setKindFilter] = useState<string>('all');
  const [search, setSearch] = useState<string>('');
  const [deleteAccountTarget, setDeleteAccountTarget] = useState<Account | null>(null);
  const [isDeleting, setIsDeleting] = useState(false);

  const getInitials = (name: string) => {
    const parts = name.trim().split(/\s+/).filter(Boolean);
    if (parts.length === 0) return '؟';
    if (parts.length === 1) return parts[0].slice(0, 2);
    return `${parts[0].charAt(0)}${parts[1].charAt(0)}`;
  };

  const filtered = accounts.filter((acc) => {
    const matchesKind = kindFilter === 'all' || acc.kind === kindFilter;
    const matchesSearch =
      acc.name.toLowerCase().includes(search.toLowerCase()) ||
      (acc.phone && acc.phone.includes(search)) ||
      (acc.category && acc.category.toLowerCase().includes(search.toLowerCase()));
    return matchesKind && matchesSearch;
  });

  const handleConfirmDelete = async () => {
    if (!deleteAccountTarget) return;
    setIsDeleting(true);
    try {
      await api.deleteAccount(deleteAccountTarget.id);
      onShowToast(`تم حذف الحساب "${deleteAccountTarget.name}" بنجاح`, 'success');
      setDeleteAccountTarget(null);
      onRefresh();
    } catch (err: any) {
      onShowToast(err.message || 'فشل حذف الحساب', 'error');
    } finally {
      setIsDeleting(false);
    }
  };

  const formatMoney = (val: number, cur = 'ر.ي') => {
    return `${new Intl.NumberFormat('ar-YE').format(Math.round(val || 0))} ${cur}`;
  };

  const handleQuickWhatsAppReminder = (acc: Account) => {
    const phone = (acc.whatsapp || acc.phone || '').replace(/[^0-9]/g, '');
    const bal = Math.abs(acc.balance || 0);
    const text = `السلام عليكم ورحمة الله،
الأخ/الأخت: ${acc.name} المحترم،
نود تذكيركم بلطف بأن الرصيد المستحق عليكم هو: ${formatMoney(bal, acc.currency)}
شاكرين ومقدرين لكم حسن التعاون والاهتمام.`;

    const url = phone
      ? `https://wa.me/${phone}?text=${encodeURIComponent(text)}`
      : `https://wa.me/?text=${encodeURIComponent(text)}`;
    window.open(url, '_blank');
  };

  return (
    <div className="space-y-4">
      {/* Header filter & search */}
      <div className="bg-white rounded-2xl p-4 border border-slate-200 shadow-xs flex flex-col sm:flex-row sm:items-center justify-between gap-3">
        <div className="flex items-center gap-2 overflow-x-auto pb-1 sm:pb-0">
          <button
            onClick={() => setKindFilter('all')}
            className={`px-3 py-1.5 rounded-xl text-xs font-bold transition-colors ${
              kindFilter === 'all'
                ? 'bg-sky-600 text-white shadow-xs'
                : 'bg-slate-100 text-slate-600 hover:bg-slate-200'
            }`}
          >
            جميع الحسابات ({accounts.length})
          </button>
          <button
            onClick={() => setKindFilter('customer')}
            className={`px-3 py-1.5 rounded-xl text-xs font-bold transition-colors ${
              kindFilter === 'customer'
                ? 'bg-sky-600 text-white shadow-xs'
                : 'bg-slate-100 text-slate-600 hover:bg-slate-200'
            }`}
          >
            عملاء ({accounts.filter((a) => a.kind === 'customer').length})
          </button>
          <button
            onClick={() => setKindFilter('supplier')}
            className={`px-3 py-1.5 rounded-xl text-xs font-bold transition-colors ${
              kindFilter === 'supplier'
                ? 'bg-sky-600 text-white shadow-xs'
                : 'bg-slate-100 text-slate-600 hover:bg-slate-200'
            }`}
          >
            موردون ({accounts.filter((a) => a.kind === 'supplier').length})
          </button>
          <button
            onClick={() => setKindFilter('cash')}
            className={`px-3 py-1.5 rounded-xl text-xs font-bold transition-colors ${
              kindFilter === 'cash'
                ? 'bg-sky-600 text-white shadow-xs'
                : 'bg-slate-100 text-slate-600 hover:bg-slate-200'
            }`}
          >
            صناديق نقدية ({accounts.filter((a) => a.kind === 'cash').length})
          </button>
        </div>

        <div className="flex items-center gap-2">
          <div className="relative flex-1 sm:w-64">
            <Search className="w-4 h-4 absolute right-3 top-3 text-slate-400" />
            <input
              id="input-account-search"
              type="text"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="بحث بالاسم أو الهاتف..."
              className="w-full pr-9 pl-3 py-2 bg-slate-50 border border-slate-200 rounded-xl text-xs focus:bg-white focus:outline-hidden"
            />
          </div>

          <button
            id="btn-sync-accounts"
            onClick={onRefresh}
            title="تحديث قائمة الحسابات"
            className="flex items-center gap-1.5 px-3 py-2 text-xs font-bold bg-slate-50 hover:bg-slate-100 text-slate-700 border border-slate-200 rounded-xl shadow-xs transition-colors shrink-0"
          >
            <RefreshCw className="w-3.5 h-3.5" />
            <span className="hidden sm:inline">تحديث</span>
          </button>

          <button
            id="btn-add-account-view"
            onClick={() => onOpenAccountModal()}
            className="flex items-center gap-1.5 px-3.5 py-2 text-xs font-bold bg-sky-600 hover:bg-sky-700 text-white rounded-xl shadow-xs transition-colors shrink-0"
          >
            <Plus className="w-4 h-4" />
            <span>حساب جديد</span>
          </button>
        </div>
      </div>

      {/* Desktop Accounts Table */}
      <div className="hidden md:block bg-white rounded-2xl border border-slate-200 shadow-xs overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-right text-xs">
            <thead className="bg-slate-50/80 border-b border-slate-200 text-slate-500 font-bold">
              <tr>
                <th className="py-3.5 px-4">الحساب</th>
                <th className="py-3.5 px-4">النوع / الفئة</th>
                <th className="py-3.5 px-4">الرصيد الصافي</th>
                <th className="py-3.5 px-4">بيانات التواصل</th>
                <th className="py-3.5 px-4 text-left">إجراءات وكشف حساب</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {filtered.length === 0 ? (
                <tr>
                  <td colSpan={5} className="py-12 text-center text-slate-400">
                    لم يتم العثور على حسابات مطابقة
                  </td>
                </tr>
              ) : (
                filtered.map((acc) => {
                  const bal = acc.balance || 0;
                  const isDebit = bal > 0; // مستحق لنا / مدين
                  const isCredit = bal < 0; // مستحق له / دائن
                  return (
                    <tr key={acc.id} className="hover:bg-slate-50/70 transition-colors">
                      {/* Name */}
                      <td className="py-3.5 px-4">
                        <div className="flex items-center gap-3">
                          <div className="w-9 h-9 rounded-xl bg-sky-100 text-sky-700 font-black text-xs flex items-center justify-center shrink-0">
                            {acc.name.slice(0, 1)}
                          </div>
                          <div>
                            <div className="font-extrabold text-slate-800 text-xs">{acc.name}</div>
                            {acc.address && (
                              <div className="text-[10px] text-slate-400">{acc.address}</div>
                            )}
                          </div>
                        </div>
                      </td>

                      {/* Kind / Category */}
                      <td className="py-3.5 px-4">
                        <div className="flex items-center gap-1.5">
                          <span
                            className={`text-[10px] px-2 py-0.5 rounded-full font-bold ${
                              acc.kind === 'customer'
                                ? 'bg-sky-50 text-sky-700 border border-sky-200'
                                : acc.kind === 'supplier'
                                ? 'bg-amber-50 text-amber-700 border border-amber-200'
                                : 'bg-emerald-50 text-emerald-700 border border-emerald-200'
                            }`}
                          >
                            {acc.kind === 'customer' ? 'عميل' : acc.kind === 'supplier' ? 'مورد' : 'صندوق'}
                          </span>
                          {acc.category && (
                            <span className="text-[10px] text-slate-500 bg-slate-100 px-2 py-0.5 rounded-md">
                              {acc.category}
                            </span>
                          )}
                        </div>
                      </td>

                      {/* Net Balance */}
                      <td className="py-3.5 px-4 font-mono">
                        <div
                          className={`text-xs font-black ${
                            isDebit
                              ? 'text-rose-600'
                              : isCredit
                              ? 'text-emerald-600'
                              : 'text-slate-700'
                          }`}
                        >
                          {formatMoney(Math.abs(bal), acc.currency)}
                        </div>
                        <span className="text-[10px] text-slate-400">
                          {isDebit ? '🔴 عليه (مدين لنا)' : isCredit ? '🟢 له (دائن علينا)' : 'متزن'}
                        </span>
                      </td>

                      {/* Phone / Whatsapp */}
                      <td className="py-3.5 px-4">
                        <div className="flex items-center gap-2">
                          {acc.phone ? (
                            <span className="font-mono text-[11px] text-slate-700" dir="ltr">
                              {acc.phone}
                            </span>
                          ) : (
                            <span className="text-slate-300 text-[11px]">-</span>
                          )}

                          {(acc.whatsapp || acc.phone) && isDebit && (
                            <button
                              onClick={() => handleQuickWhatsAppReminder(acc)}
                              className="text-emerald-600 hover:text-emerald-700 p-1 rounded-md hover:bg-emerald-50 transition-colors"
                              title="إرسال تذكير بالرصيد عبر واتساب"
                            >
                              <MessageCircle className="w-3.5 h-3.5" />
                            </button>
                          )}
                        </div>
                      </td>

                      {/* Actions */}
                      <td className="py-3.5 px-4 text-left">
                        <div className="flex items-center justify-end gap-1.5">
                          {/* Dedicated Statement Button */}
                          <button
                            onClick={() => onOpenStatement(acc)}
                            className="px-2.5 py-1.5 rounded-lg bg-slate-100 hover:bg-slate-200 text-slate-700 text-xs font-bold flex items-center gap-1 transition-colors"
                            title="عرض كشف حساب تفصيلي"
                          >
                            <FileText className="w-3.5 h-3.5 text-sky-600" />
                            <span className="hidden sm:inline">كشف حساب</span>
                          </button>

                          <button
                            onClick={() => onOpenTxModal(acc.id)}
                            className="p-1.5 rounded-lg bg-sky-50 text-sky-600 hover:bg-sky-100 transition-colors"
                            title="إضافة عملية لهذا الحساب"
                          >
                            <Plus className="w-3.5 h-3.5" />
                          </button>
                          <button
                            onClick={() => onOpenAccountModal(acc)}
                            className="p-1.5 rounded-lg text-slate-500 hover:text-slate-800 hover:bg-slate-100 transition-colors"
                            title="تعديل"
                          >
                            <Edit2 className="w-3.5 h-3.5" />
                          </button>
                          <button
                            onClick={() => setDeleteAccountTarget(acc)}
                            className="p-1.5 rounded-lg text-slate-400 hover:text-rose-600 hover:bg-rose-50 transition-colors"
                            title="حذف"
                          >
                            <Trash2 className="w-3.5 h-3.5" />
                          </button>
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

      {/* Mobile & Side-Preview Cards */}
      <div className="md:hidden space-y-3">
        {filtered.length === 0 ? (
          <div className="bg-white rounded-2xl p-8 text-center text-slate-400 border border-slate-200">
            لم يتم العثور على حسابات مطابقة
          </div>
        ) : (
          filtered.map((acc) => {
            const bal = acc.balance || 0;
            const isDebit = bal > 0;
            const isCredit = bal < 0;
            const initials = getInitials(acc.name);
            return (
              <div
                key={acc.id}
                className="bg-white rounded-2xl p-4 border border-slate-200 shadow-xs hover:border-sky-300 transition-all"
              >
                <div className="flex items-center justify-between gap-3">
                  <div className="flex items-center gap-3 min-w-0">
                    <div className="w-11 h-11 rounded-full bg-sky-100 text-sky-700 font-extrabold text-sm flex items-center justify-center shrink-0 border border-sky-200">
                      {initials}
                    </div>
                    <div className="min-w-0">
                      <div className="font-extrabold text-slate-900 text-sm truncate">{acc.name}</div>
                      <div className="text-xs text-slate-500 flex items-center gap-1.5 mt-0.5">
                        {acc.phone && <span dir="ltr">{acc.phone}</span>}
                        {acc.phone && <span>•</span>}
                        <span className="font-medium">
                          {acc.kind === 'customer' ? 'عميل' : acc.kind === 'supplier' ? 'مورد' : 'صندوق'}
                        </span>
                        {acc.currency && <span className="text-[11px] text-slate-400">({acc.currency})</span>}
                      </div>
                    </div>
                  </div>

                  <div className="text-left shrink-0">
                    <div
                      className={`text-sm font-black ${
                        isDebit ? 'text-rose-600' : isCredit ? 'text-emerald-600' : 'text-slate-600'
                      }`}
                    >
                      {formatMoney(Math.abs(bal), acc.currency)} {isDebit ? '-' : isCredit ? '+' : ''}
                    </div>
                    <span className="text-[10px] font-bold text-slate-400">
                      {isDebit ? 'عليكم (دين)' : isCredit ? 'لكم (رصيد)' : 'متزن'}
                    </span>
                  </div>
                </div>

                <div className="mt-3.5 pt-3 border-t border-slate-100 flex items-center justify-between">
                  <div className="flex items-center gap-1.5">
                    <button
                      onClick={() => onOpenStatement(acc)}
                      className="px-2.5 py-1.5 rounded-xl bg-slate-100 hover:bg-slate-200 text-slate-700 font-bold flex items-center gap-1 text-xs transition-colors"
                    >
                      <FileText className="w-3.5 h-3.5 text-sky-600" />
                      <span>كشف حساب</span>
                    </button>
                    {(acc.whatsapp || acc.phone) && isDebit && (
                      <button
                        onClick={() => handleQuickWhatsAppReminder(acc)}
                        className="px-2.5 py-1.5 rounded-xl bg-emerald-50 text-emerald-700 hover:bg-emerald-100 font-bold flex items-center gap-1 text-xs transition-colors"
                      >
                        <MessageCircle className="w-3.5 h-3.5" />
                        <span>واتساب</span>
                      </button>
                    )}
                  </div>

                  <div className="flex items-center gap-1">
                    <button
                      onClick={() => onOpenTxModal(acc.id)}
                      className="p-1.5 rounded-xl bg-sky-50 text-sky-600 hover:bg-sky-100 transition-colors"
                      title="إضافة عملية"
                    >
                      <Plus className="w-4 h-4" />
                    </button>
                    <button
                      onClick={() => onOpenAccountModal(acc)}
                      className="p-1.5 rounded-xl text-slate-500 hover:bg-slate-100 transition-colors"
                      title="تعديل"
                    >
                      <Edit2 className="w-4 h-4" />
                    </button>
                    <button
                      onClick={() => setDeleteAccountTarget(acc)}
                      className="p-1.5 rounded-xl text-slate-400 hover:text-rose-600 hover:bg-rose-50 transition-colors"
                      title="حذف"
                    >
                      <Trash2 className="w-4 h-4" />
                    </button>
                  </div>
                </div>
              </div>
            );
          })
        )}
      </div>

      {/* In-App Delete Confirmation */}
      <ConfirmModal
        isOpen={Boolean(deleteAccountTarget)}
        title="تأكيد حذف الحساب"
        message={`هل أنت متأكد من رغبتك في حذف الحساب "${deleteAccountTarget?.name}"؟ سيتم الاحتفاظ بالحركات المرتبطة به في السجل العام.`}
        confirmLabel="حذف الحساب"
        cancelLabel="تراجع"
        variant="danger"
        isLoading={isDeleting}
        onConfirm={handleConfirmDelete}
        onCancel={() => setDeleteAccountTarget(null)}
      />
    </div>
  );
};
