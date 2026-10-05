import React, { useState, useMemo } from 'react';
import {
  X,
  Printer,
  MessageCircle,
  Calendar,
  DollarSign,
  ArrowDownLeft,
  ArrowUpRight,
  Filter,
  Share2,
  Copy,
  Check,
} from 'lucide-react';
import { Account, Transaction } from '../types';

interface AccountStatementModalProps {
  isOpen: boolean;
  account: Account | null;
  transactions: Transaction[];
  businessName?: string;
  onClose: () => void;
  onShowToast: (msg: string, type?: 'success' | 'error' | 'info') => void;
}

export const AccountStatementModal: React.FC<AccountStatementModalProps> = ({
  isOpen,
  account,
  transactions,
  businessName = 'سجل المبيعات والديون',
  onClose,
  onShowToast,
}) => {
  const [dateRange, setDateRange] = useState<'all' | 'today' | 'week' | 'month'>('all');
  const [copied, setCopied] = useState(false);

  // Filter transactions belonging to this account
  const accountTransactions = useMemo(() => {
    if (!account) return [];
    const accTxs = transactions.filter((t) => t.account_id === account.id);
    
    // Sort oldest to newest for calculating running balance
    accTxs.sort((a, b) => new Date(a.date).getTime() - new Date(b.date).getTime());

    const now = new Date();
    return accTxs.filter((tx) => {
      const txDate = new Date(tx.date);
      if (dateRange === 'today') {
        return txDate.toDateString() === now.toDateString();
      }
      if (dateRange === 'week') {
        const weekAgo = new Date();
        weekAgo.setDate(now.getDate() - 7);
        return txDate >= weekAgo;
      }
      if (dateRange === 'month') {
        return txDate.getMonth() === now.getMonth() && txDate.getFullYear() === now.getFullYear();
      }
      return true;
    });
  }, [account, transactions, dateRange]);

  // Running balance calculation
  const statementRows = useMemo(() => {
    let running = account?.opening_balance || 0;
    return accountTransactions.map((tx) => {
      const isDebit = tx.type === 'debit' || tx.type === 'outflow';
      const isCredit = tx.type === 'credit' || tx.type === 'inflow';
      
      const debitAmount = isDebit ? tx.amount : 0;
      const creditAmount = isCredit ? tx.amount : 0;

      // In client accounts: debit increases what they owe us (+), credit decreases what they owe us (-)
      running += debitAmount - creditAmount;

      return {
        ...tx,
        debitAmount,
        creditAmount,
        runningBalance: running,
      };
    });
  }, [account, accountTransactions]);

  const totalDebit = statementRows.reduce((sum, r) => sum + r.debitAmount, 0);
  const totalCredit = statementRows.reduce((sum, r) => sum + r.creditAmount, 0);
  const finalBalance = (account?.opening_balance || 0) + totalDebit - totalCredit;

  if (!isOpen || !account) return null;

  const formatMoney = (val: number, cur = account.currency || 'ر.ي') => {
    return `${new Intl.NumberFormat('ar-YE').format(Math.round(val || 0))} ${cur}`;
  };

  const generateWhatsAppMessage = () => {
    const isDebit = finalBalance > 0;
    const statusText = isDebit
      ? `الرصيد المتبقي عليكم: ${formatMoney(Math.abs(finalBalance))}`
      : finalBalance < 0
      ? `الرصيد المتبقي لكم: ${formatMoney(Math.abs(finalBalance))}`
      : 'الرصيد متزن بالكامل (0 ر.ي)';

    const text = `السلام عليكم ورحمة الله،
كشف حساب من: ${businessName}
العميل / الحساب: ${account.name}
التاريخ: ${new Date().toLocaleDateString('ar-YE')}
----------------------------
الرصيد الافتتاحي: ${formatMoney(account.opening_balance || 0)}
إجمالي المشتريات/المدين: ${formatMoney(totalDebit)}
إجمالي المسدد/الدائن: ${formatMoney(totalCredit)}
----------------------------
🔹 ${statusText}

شاكرين لكم حسن التعامل والمصداقية.`;

    return text;
  };

  const handleShareWhatsApp = () => {
    const text = generateWhatsAppMessage();
    const phone = (account.whatsapp || account.phone || '').replace(/[^0-9]/g, '');
    const url = phone
      ? `https://wa.me/${phone}?text=${encodeURIComponent(text)}`
      : `https://wa.me/?text=${encodeURIComponent(text)}`;
    window.open(url, '_blank');
    onShowToast('تم تجهيز كشف الحساب للإرسال عبر واتساب', 'success');
  };

  const handleCopyText = () => {
    const text = generateWhatsAppMessage();
    navigator.clipboard.writeText(text);
    setCopied(true);
    setTimeout(() => setCopied(false), 2500);
    onShowToast('تم نسخ نص كشف الحساب للحافظة', 'success');
  };

  const handlePrint = () => {
    try {
      window.print();
    } catch {
      onShowToast('يمكنك طباعة الكشف عبر أمر الطباعة في المتصفح', 'info');
    }
  };

  return (
    <div className="fixed inset-0 bg-slate-900/60 backdrop-blur-xs flex items-center justify-center p-4 z-50 animate-in fade-in duration-200">
      <div className="bg-white rounded-3xl p-6 max-w-2xl w-full border border-slate-200 shadow-2xl space-y-4 max-h-[90vh] flex flex-col text-right">
        {/* Header */}
        <div className="flex items-center justify-between pb-3 border-b border-slate-100">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 rounded-2xl bg-sky-100 text-sky-700 flex items-center justify-center font-black text-sm">
              {account.name.slice(0, 1)}
            </div>
            <div>
              <div className="flex items-center gap-2">
                <h3 className="font-extrabold text-sm text-slate-900">كشف حساب تفصيلي: {account.name}</h3>
                <span className="text-[10px] px-2 py-0.5 rounded-full font-bold bg-sky-50 text-sky-700 border border-sky-200">
                  {account.kind === 'customer' ? 'عميل' : account.kind === 'supplier' ? 'مورد' : 'صندوق'}
                </span>
              </div>
              <div className="text-[11px] text-slate-400">
                {account.phone ? `هاتف: ${account.phone}` : 'بدون هاتف'} • {account.address || 'اليمن'}
              </div>
            </div>
          </div>
          <button
            onClick={onClose}
            className="p-1 rounded-lg text-slate-400 hover:text-slate-600 transition-colors"
          >
            <X className="w-5 h-5" />
          </button>
        </div>

        {/* Date Filter & Actions */}
        <div className="flex flex-wrap items-center justify-between gap-2 bg-slate-50 p-2.5 rounded-2xl border border-slate-100">
          <div className="flex items-center gap-1.5">
            <Filter className="w-3.5 h-3.5 text-slate-400" />
            <button
              onClick={() => setDateRange('all')}
              className={`px-2.5 py-1 rounded-lg text-xs font-bold transition-colors ${
                dateRange === 'all' ? 'bg-sky-600 text-white shadow-xs' : 'text-slate-600 hover:bg-slate-200'
              }`}
            >
              كافة الفترات
            </button>
            <button
              onClick={() => setDateRange('today')}
              className={`px-2.5 py-1 rounded-lg text-xs font-bold transition-colors ${
                dateRange === 'today' ? 'bg-sky-600 text-white shadow-xs' : 'text-slate-600 hover:bg-slate-200'
              }`}
            >
              اليوم
            </button>
            <button
              onClick={() => setDateRange('week')}
              className={`px-2.5 py-1 rounded-lg text-xs font-bold transition-colors ${
                dateRange === 'week' ? 'bg-sky-600 text-white shadow-xs' : 'text-slate-600 hover:bg-slate-200'
              }`}
            >
              آخر 7 أيام
            </button>
            <button
              onClick={() => setDateRange('month')}
              className={`px-2.5 py-1 rounded-lg text-xs font-bold transition-colors ${
                dateRange === 'month' ? 'bg-sky-600 text-white shadow-xs' : 'text-slate-600 hover:bg-slate-200'
              }`}
            >
              هذا الشهر
            </button>
          </div>

          <div className="flex items-center gap-2">
            <button
              onClick={handleCopyText}
              className="p-1.5 rounded-lg bg-white border border-slate-200 text-slate-600 hover:text-slate-900 text-xs font-bold flex items-center gap-1 shadow-2xs"
              title="نسخ نص الكشف"
            >
              {copied ? <Check className="w-3.5 h-3.5 text-emerald-600" /> : <Copy className="w-3.5 h-3.5" />}
              <span className="hidden sm:inline">{copied ? 'تم النسخ' : 'نسخ النص'}</span>
            </button>
            <button
              onClick={handleShareWhatsApp}
              className="px-3 py-1.5 rounded-lg bg-emerald-600 hover:bg-emerald-700 text-white text-xs font-bold flex items-center gap-1.5 shadow-2xs transition-colors"
            >
              <MessageCircle className="w-3.5 h-3.5" />
              <span>إرسال بالواتساب</span>
            </button>
            <button
              onClick={handlePrint}
              className="p-1.5 rounded-lg bg-white border border-slate-200 text-slate-600 hover:text-slate-900 text-xs font-bold flex items-center gap-1 shadow-2xs"
              title="طباعة كشف الحساب"
            >
              <Printer className="w-3.5 h-3.5" />
              <span className="hidden sm:inline">طباعة</span>
            </button>
          </div>
        </div>

        {/* Balance Summary Cards */}
        <div className="grid grid-cols-3 gap-3">
          <div className="p-3 bg-rose-50/70 border border-rose-100 rounded-2xl">
            <span className="text-[10px] font-bold text-rose-700 block">إجمالي عليه (مشتريات/مدين)</span>
            <span className="text-sm font-black text-rose-600 font-mono mt-0.5 block">
              {formatMoney(totalDebit)}
            </span>
          </div>
          <div className="p-3 bg-emerald-50/70 border border-emerald-100 rounded-2xl">
            <span className="text-[10px] font-bold text-emerald-700 block">إجمالي له (مدفوعات/دائن)</span>
            <span className="text-sm font-black text-emerald-600 font-mono mt-0.5 block">
              {formatMoney(totalCredit)}
            </span>
          </div>
          <div className="p-3 bg-slate-100/80 border border-slate-200 rounded-2xl">
            <span className="text-[10px] font-bold text-slate-600 block">الرصيد الصافي النهائي</span>
            <span
              className={`text-sm font-black font-mono mt-0.5 block ${
                finalBalance > 0 ? 'text-rose-600' : finalBalance < 0 ? 'text-emerald-600' : 'text-slate-800'
              }`}
            >
              {formatMoney(Math.abs(finalBalance))}
            </span>
            <span className="text-[9px] text-slate-500 font-medium">
              {finalBalance > 0 ? 'مستحق عليه (لنا)' : finalBalance < 0 ? 'مستحق له (علينا)' : 'رصيد متزن'}
            </span>
          </div>
        </div>

        {/* Transactions Table */}
        <div className="flex-1 overflow-y-auto border border-slate-200 rounded-2xl">
          <table className="w-full text-right text-xs">
            <thead className="bg-slate-50/90 border-b border-slate-200 text-slate-500 font-bold sticky top-0">
              <tr>
                <th className="py-2.5 px-3">التاريخ</th>
                <th className="py-2.5 px-3">البيان / المرجع</th>
                <th className="py-2.5 px-3 text-rose-600">مدين (+)</th>
                <th className="py-2.5 px-3 text-emerald-600">دائن (-)</th>
                <th className="py-2.5 px-3">الرصيد</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {/* Opening Balance Row */}
              <tr className="bg-slate-50/40 font-bold text-slate-600">
                <td className="py-2 px-3 font-mono text-[11px]">-</td>
                <td className="py-2 px-3">رصيد افتتاحي سابق</td>
                <td className="py-2 px-3 font-mono text-rose-600">
                  {(account.opening_balance || 0) > 0 ? formatMoney(account.opening_balance || 0) : '-'}
                </td>
                <td className="py-2 px-3 font-mono text-emerald-600">
                  {(account.opening_balance || 0) < 0 ? formatMoney(Math.abs(account.opening_balance || 0)) : '-'}
                </td>
                <td className="py-2 px-3 font-mono font-black text-slate-800">
                  {formatMoney(account.opening_balance || 0)}
                </td>
              </tr>

              {statementRows.length === 0 ? (
                <tr>
                  <td colSpan={5} className="py-8 text-center text-slate-400 text-xs">
                    لا توجد حركات مالية مسجلة في هذه الفترة
                  </td>
                </tr>
              ) : (
                statementRows.map((row) => (
                  <tr key={row.id} className="hover:bg-slate-50">
                    <td className="py-2 px-3 font-mono text-[11px] text-slate-500 whitespace-nowrap">
                      {new Date(row.date).toLocaleDateString('ar-YE')}
                    </td>
                    <td className="py-2 px-3 text-slate-700">
                      <div>{row.description || 'عملية مالية'}</div>
                      {row.reference && (
                        <span className="text-[10px] text-slate-400 font-mono">مرجع: {row.reference}</span>
                      )}
                    </td>
                    <td className="py-2 px-3 font-mono font-bold text-rose-600">
                      {row.debitAmount > 0 ? formatMoney(row.debitAmount) : '-'}
                    </td>
                    <td className="py-2 px-3 font-mono font-bold text-emerald-600">
                      {row.creditAmount > 0 ? formatMoney(row.creditAmount) : '-'}
                    </td>
                    <td className="py-2 px-3 font-mono font-black text-slate-800">
                      {formatMoney(row.runningBalance)}
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>

        {/* Footer */}
        <div className="flex items-center justify-between pt-2 text-xs text-slate-500">
          <span>عدد العمليات: {statementRows.length}</span>
          <button
            onClick={onClose}
            className="px-5 py-2 rounded-xl bg-slate-900 hover:bg-slate-800 text-white font-bold transition-colors"
          >
            إغلاق الكشف
          </button>
        </div>
      </div>
    </div>
  );
};
