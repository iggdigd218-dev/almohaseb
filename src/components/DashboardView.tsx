import React, { useState, useEffect, useMemo } from 'react';
import {
  TrendingUp,
  ArrowDownLeft,
  Users,
  AlertTriangle,
  ArrowUpRight,
  Clock,
  Phone,
  ShieldCheck,
  Cloud,
  CloudOff,
  RefreshCw,
  CheckCircle2,
} from 'lucide-react';
import { DashboardData, Transaction, SyncQueueStats } from '../types';
import { subscribeSyncStatus, getWorkspaceMode, triggerImmediateSync } from '../services/syncQueueService';

interface DashboardViewProps {
  data: DashboardData | null;
  onSelectAccount: (accountId: number) => void;
  onOpenTxModal: () => void;
}

export const DashboardView: React.FC<DashboardViewProps> = ({
  data,
  onSelectAccount,
  onOpenTxModal,
}) => {
  const [syncStats, setSyncStats] = useState<SyncQueueStats>({
    total: 0,
    pending: 0,
    syncing: 0,
    synced: 0,
    failed: 0,
    last_sync_timestamp: 0,
  });
  const [isOnline, setIsOnline] = useState<boolean>(typeof navigator !== 'undefined' ? navigator.onLine : true);
  const [isSyncing, setIsSyncing] = useState<boolean>(false);
  const mode = getWorkspaceMode();

  useEffect(() => {
    const unsubscribe = subscribeSyncStatus((stats, online, syncing) => {
      setSyncStats(stats);
      setIsOnline(online);
      setIsSyncing(syncing);
    });
    return () => unsubscribe();
  }, []);
  const formatMoney = (num: number, cur = 'ر.ي') => {
    return `${new Intl.NumberFormat('ar-YE').format(Math.round(num || 0))} ${cur}`;
  };

  const getTxTypeLabel = (type: string) => {
    switch (type) {
      case 'debit':
        return { text: 'عليه (مدين)', color: 'text-rose-600 bg-rose-50 border-rose-200' };
      case 'credit':
        return { text: 'له (دائن)', color: 'text-emerald-600 bg-emerald-50 border-emerald-200' };
      case 'inflow':
        return { text: 'سند قبض', color: 'text-sky-600 bg-sky-50 border-sky-200' };
      case 'outflow':
        return { text: 'سند صرف', color: 'text-amber-600 bg-amber-50 border-amber-200' };
      case 'revenue':
        return { text: 'إيراد', color: 'text-emerald-700 bg-emerald-100 border-emerald-300' };
      case 'expense':
        return { text: 'مصروف', color: 'text-orange-600 bg-orange-50 border-orange-200' };
      default:
        return { text: type, color: 'text-slate-600 bg-slate-100 border-slate-200' };
    }
  };

  return (
    <div className="space-y-6">
      {/* System Status & Sync Bar */}
      <div className="bg-white rounded-2xl p-3 px-4 border border-slate-200 shadow-xs flex flex-wrap items-center justify-between gap-3 text-xs">
        <div className="flex items-center gap-2.5">
          <div className="w-8 h-8 rounded-xl bg-sky-50 text-sky-600 flex items-center justify-center font-bold">
            <ShieldCheck className="w-4 h-4" />
          </div>
          <div>
            <div className="flex items-center gap-2">
              <span className="font-extrabold text-slate-800">
                {mode === 'individual' ? 'الحساب الفردي (تشغيل محلي 100%)' : 'لوحة إدارة المنشأة (مزامنة فورية)'}
              </span>
              <span className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] font-bold ${
                isOnline ? 'bg-emerald-50 text-emerald-700 border border-emerald-200' : 'bg-amber-50 text-amber-700 border border-amber-200'
              }`}>
                {isOnline ? (
                  <>
                    <span className="w-1.5 h-1.5 rounded-full bg-emerald-500 animate-pulse" />
                    <span>متصل</span>
                  </>
                ) : (
                  <>
                    <CloudOff className="w-3 h-3 text-amber-600" />
                    <span>وضع عدم الاتصال (حفظ محلي SQLite)</span>
                  </>
                )}
              </span>
            </div>
            <p className="text-[11px] text-slate-400 mt-0.5">
              قاعدة البيانات المحلية تستجيب فورياً لجميع العمليات دون توقف
            </p>
          </div>
        </div>

        {mode === 'enterprise' && (
          <div className="flex items-center gap-3">
            {syncStats.pending > 0 ? (
              <span className="inline-flex items-center gap-1.5 text-amber-700 bg-amber-50 border border-amber-200 px-2.5 py-1 rounded-xl text-[11px] font-bold">
                <RefreshCw className={`w-3.5 h-3.5 ${isSyncing ? 'animate-spin' : ''}`} />
                <span>طابور المزامنة: {syncStats.pending} معلقة</span>
              </span>
            ) : (
              <span className="inline-flex items-center gap-1 text-emerald-700 bg-emerald-50 border border-emerald-200 px-2.5 py-1 rounded-xl text-[11px] font-bold">
                <CheckCircle2 className="w-3.5 h-3.5" />
                <span>كافة البيانات متزامنة</span>
              </span>
            )}
            <button
              onClick={() => triggerImmediateSync()}
              disabled={isSyncing || !isOnline}
              className="p-1.5 rounded-lg border border-slate-200 hover:bg-slate-50 text-slate-600 transition-colors disabled:opacity-40"
              title="مزامنة فورية الآن"
            >
              <RefreshCw className={`w-3.5 h-3.5 ${isSyncing ? 'animate-spin' : ''}`} />
            </button>
          </div>
        )}
      </div>

      {/* Stats Cards */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        {/* Total Sales */}
        <div className="bg-white rounded-2xl p-4 border border-slate-200 shadow-xs relative overflow-hidden group">
          <div className="absolute top-0 right-0 left-0 h-1 bg-sky-500" />
          <div className="flex items-start justify-between">
            <div>
              <span className="text-xs font-semibold text-slate-500">إجمالي المبيعات</span>
              <div className="text-xl font-black text-slate-900 mt-1 font-mono">
                {formatMoney(data?.totalSales || 0)}
              </div>
            </div>
            <div className="w-10 h-10 rounded-xl bg-sky-50 text-sky-600 flex items-center justify-center">
              <TrendingUp className="w-5 h-5" />
            </div>
          </div>
          <div className="mt-3 text-[11px] text-slate-400 flex items-center gap-1">
            <span>من كافة الفواتير والعمليات</span>
          </div>
        </div>

        {/* Total Debts */}
        <div className="bg-white rounded-2xl p-4 border border-slate-200 shadow-xs relative overflow-hidden group">
          <div className="absolute top-0 right-0 left-0 h-1 bg-emerald-500" />
          <div className="flex items-start justify-between">
            <div>
              <span className="text-xs font-semibold text-slate-500">الذمم المدينة (مستحق لنا)</span>
              <div className="text-xl font-black text-emerald-600 mt-1 font-mono">
                {formatMoney(data?.totalDebts || 0)}
              </div>
            </div>
            <div className="w-10 h-10 rounded-xl bg-emerald-50 text-emerald-600 flex items-center justify-center">
              <ArrowDownLeft className="w-5 h-5" />
            </div>
          </div>
          <div className="mt-3 text-[11px] text-slate-400 flex items-center gap-1">
            <span>ديون العملاء الإجمالية</span>
          </div>
        </div>

        {/* Accounts Count */}
        <div className="bg-white rounded-2xl p-4 border border-slate-200 shadow-xs relative overflow-hidden">
          <div className="absolute top-0 right-0 left-0 h-1 bg-indigo-500" />
          <div className="flex items-start justify-between">
            <div>
              <span className="text-xs font-semibold text-slate-500">الحسابات والعملاء</span>
              <div className="text-xl font-black text-slate-900 mt-1 font-mono">
                {data?.accountsCount || 0} حساب
              </div>
            </div>
            <div className="w-10 h-10 rounded-xl bg-indigo-50 text-indigo-600 flex items-center justify-center">
              <Users className="w-5 h-5" />
            </div>
          </div>
          <div className="mt-3 text-[11px] text-slate-400 flex items-center gap-1">
            <span>إجمالي العملاء والموردين المسجلين</span>
          </div>
        </div>

        {/* Low Stock Alerts */}
        <div className="bg-white rounded-2xl p-4 border border-slate-200 shadow-xs relative overflow-hidden">
          <div className="absolute top-0 right-0 left-0 h-1 bg-rose-500" />
          <div className="flex items-start justify-between">
            <div>
              <span className="text-xs font-semibold text-slate-500">تنبيهات نقص المخزون</span>
              <div className="text-xl font-black text-rose-600 mt-1 font-mono">
                {data?.lowStock || 0} صنف
              </div>
            </div>
            <div className="w-10 h-10 rounded-xl bg-rose-50 text-rose-600 flex items-center justify-center">
              <AlertTriangle className="w-5 h-5" />
            </div>
          </div>
          <div className="mt-3 text-[11px] text-slate-400 flex items-center gap-1">
            <span>أصناف بلغت حد الطلب الأدنى</span>
          </div>
        </div>
      </div>

      {/* Grid: Top Debtors + Recent Transactions */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Top Debtors */}
        <div className="bg-white rounded-2xl border border-slate-200 shadow-xs overflow-hidden">
          <div className="p-4 border-b border-slate-100 flex items-center justify-between">
            <div className="flex items-center gap-2">
              <Users className="w-4 h-4 text-sky-600" />
              <h3 className="text-sm font-black text-slate-800">أكثر العملاء مديونية</h3>
            </div>
            <span className="text-[11px] font-bold text-slate-400">أعلى 5 ديون</span>
          </div>

          <div className="divide-y divide-slate-100">
            {(!data?.topDebtors || data.topDebtors.length === 0) ? (
              <div className="p-8 text-center text-slate-400 text-xs">
                لا توجد ديون مسجلة حالياً
              </div>
            ) : (
              data.topDebtors.map((debtor) => (
                <div
                  key={debtor.id}
                  onClick={() => onSelectAccount(debtor.id)}
                  className="p-3.5 hover:bg-slate-50 flex items-center justify-between gap-3 cursor-pointer transition-colors"
                >
                  <div className="flex items-center gap-3">
                    <div className="w-9 h-9 rounded-xl bg-sky-100 text-sky-700 font-bold text-xs flex items-center justify-center">
                      {debtor.name.slice(0, 1)}
                    </div>
                    <div>
                      <div className="text-xs font-bold text-slate-800">{debtor.name}</div>
                      <div className="text-[11px] text-slate-400 flex items-center gap-2 mt-0.5">
                        {debtor.phone && (
                          <span className="flex items-center gap-1">
                            <Phone className="w-3 h-3 text-slate-400" />
                            <span dir="ltr">{debtor.phone}</span>
                          </span>
                        )}
                      </div>
                    </div>
                  </div>

                  <div className="text-left font-mono">
                    <div className="text-xs font-black text-rose-600">
                      {formatMoney(debtor.balance)}
                    </div>
                    <span className="text-[10px] text-slate-400">مستحق عليه</span>
                  </div>
                </div>
              ))
            )}
          </div>
        </div>

        {/* Recent Transactions */}
        <div className="bg-white rounded-2xl border border-slate-200 shadow-xs overflow-hidden">
          <div className="p-4 border-b border-slate-100 flex items-center justify-between">
            <div className="flex items-center gap-2">
              <Clock className="w-4 h-4 text-sky-600" />
              <h3 className="text-sm font-black text-slate-800">آخر العمليات المسجلة</h3>
            </div>
            <button
              onClick={onOpenTxModal}
              className="text-xs font-bold text-sky-600 hover:text-sky-700"
            >
              + إضافة عملية
            </button>
          </div>

          <div className="divide-y divide-slate-100 max-h-[380px] overflow-y-auto">
            {(!data?.recentTx || data.recentTx.length === 0) ? (
              <div className="p-8 text-center text-slate-400 text-xs">
                لا توجد عمليات مسجلة حتى الآن
              </div>
            ) : (
              data.recentTx.map((tx) => {
                const typeInfo = getTxTypeLabel(tx.type);
                return (
                  <div key={tx.id} className="p-3.5 hover:bg-slate-50 flex items-center justify-between gap-3">
                    <div className="flex items-center gap-3">
                      <div className="w-9 h-9 rounded-xl bg-slate-100 text-slate-700 flex items-center justify-center shrink-0">
                        {tx.type === 'debit' ? (
                          <ArrowDownLeft className="w-4 h-4 text-rose-500" />
                        ) : (
                          <ArrowUpRight className="w-4 h-4 text-emerald-500" />
                        )}
                      </div>
                      <div>
                        <div className="text-xs font-bold text-slate-800">
                          {tx.account_name || 'حساب عام'}
                        </div>
                        <div className="text-[11px] text-slate-400 flex items-center gap-2 mt-0.5">
                          <span>{tx.description || 'عملية مالية'}</span>
                          <span>•</span>
                          <span>{new Date(tx.date).toLocaleDateString('ar-YE')}</span>
                        </div>
                      </div>
                    </div>

                    <div className="text-left font-mono">
                      <div className="text-xs font-black text-slate-900">
                        {formatMoney(tx.amount, tx.currency)}
                      </div>
                      <span className={`text-[10px] px-2 py-0.5 rounded-md font-bold border ${typeInfo.color}`}>
                        {typeInfo.text}
                      </span>
                    </div>
                  </div>
                );
              })
            )}
          </div>
        </div>
      </div>
    </div>
  );
};
