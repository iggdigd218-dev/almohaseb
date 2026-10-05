import React, { useEffect, useState } from 'react';
import { subscribeSyncStatus, triggerImmediateSync, getWorkspaceMode } from '../services/syncQueueService';
import { SyncQueueStats } from '../types';

interface SyncArrowsIndicatorProps {
  onShowToast?: (msg: string, type?: 'success' | 'error' | 'info') => void;
}

export const SyncArrowsIndicator: React.FC<SyncArrowsIndicatorProps> = ({ onShowToast }) => {
  const [stats, setStats] = useState<SyncQueueStats>({
    total: 0,
    pending: 0,
    syncing: 0,
    synced: 0,
    failed: 0,
    last_sync_timestamp: 0,
  });
  const [isOnline, setIsOnline] = useState<boolean>(
    typeof navigator !== 'undefined' ? navigator.onLine : true
  );
  const [isSyncing, setIsSyncing] = useState<boolean>(false);
  const [mode, setMode] = useState<'individual' | 'enterprise'>('enterprise');

  useEffect(() => {
    setMode(getWorkspaceMode());

    const unsubscribe = subscribeSyncStatus((newStats, online, syncing) => {
      setStats(newStats);
      setIsOnline(online);
      setIsSyncing(syncing);
      setMode(getWorkspaceMode());
    });

    return () => {
      unsubscribe();
    };
  }, []);

  // الوضع الفردي المستقل (standalone): عرض شارة الأمان المحلي التام
  if (mode === 'individual') {
    return (
      <div
        className="flex items-center gap-1.5 px-2.5 py-1.5 rounded-xl bg-emerald-50 text-emerald-700 border border-emerald-200/80 text-xs font-bold"
        title="البيئة المحلية أولاً — النظام يعمل بكفاءة وسرعة فائقة محلياً على جهازك دون أي حاجة للانتظار"
      >
        <span className="w-2 h-2 rounded-full bg-emerald-500"></span>
        <span className="text-[11px]">محلي فوري (Local-First)</span>
      </div>
    );
  }

  const uploadFaulted = stats.failed > 0;
  const downloadFaulted = stats.failed > 0;
  // النبض فقط أثناء وجود عمليات فعلية قيد الإرسال وليس في وضع الخمول
  const isPushing = (isSyncing && stats.pending > 0) || stats.syncing > 0;
  const isPulling = isSyncing && stats.pending > 0;

  // تحديد ألوان الأسهم وفق حالة الاتصال والخطأ والنقل
  const upColor = !isOnline
    ? '#94a3b8'
    : uploadFaulted
    ? '#ef4444'
    : '#10b981'; // أخضر الزمرد

  const downColor = !isOnline
    ? '#94a3b8'
    : downloadFaulted
    ? '#ef4444'
    : '#0ea5e9'; // أزرق السماء

  const tooltipMsg = !isOnline
    ? 'الجهاز يعمل في الوضع المحلي غير المتصل — كافة العمليات محفوظة محلياً وفورياً'
    : uploadFaulted || downloadFaulted
    ? '⚠️ تعثرت بعض عمليات المزامنة — اضغط لإعادة المحاولة'
    : isSyncing && stats.pending > 0
    ? 'المزامنة السحابية جارية في الخلفية دون تعطيل العمل...'
    : 'البيئة المحلية أولاً: العمليات محفوظة محلياً ومستقرة سحابياً ✅ (اضغط للمزامنة الفورية)';

  const handleClick = async () => {
    try {
      if (onShowToast) {
        if (!isOnline) {
          onShowToast('البيئة المحلية أولاً: النظام يعمل بكفاءة دون اتصال وستتم المزامنة تلقائياً', 'info');
          return;
        }
        if (stats.pending > 0) {
          onShowToast('جارٍ دفع العمليات المعلقة في الخلفية...', 'info');
        }
      }

      await triggerImmediateSync();

      if (onShowToast && isOnline) {
        if (stats.failed > 0) {
          onShowToast('⚠️ تعثرت بعض العمليات — يرجى فحص الاتصال بالإنترنت', 'error');
        } else {
          onShowToast('البيئة المحلية أولاً: كافة البيانات محفوظة محلياً فوراً ومتزامنة ✅', 'success');
        }
      }
    } catch {
      if (onShowToast) {
        onShowToast('تعذر إتمام المزامنة الفورية حالياً — العمل المحلي مستمر دون انقطاع', 'error');
      }
    }
  };

  return (
    <button
      type="button"
      id="btn-sync-arrows-indicator"
      onClick={handleClick}
      title={tooltipMsg}
      aria-label="مؤشرا المزامنة اللحظية"
      className="relative flex items-center justify-center w-10 h-10 rounded-xl bg-slate-100 hover:bg-slate-200 active:scale-95 transition-all cursor-pointer border border-slate-200/80 group"
    >
      {/* رسم الأسهم المتوازية العريضة والمقتربة كما في النسخة الأصلية للمستودع */}
      <svg
        width="22"
        height="22"
        viewBox="0 0 24 24"
        fill="none"
        xmlns="http://www.w3.org/2000/svg"
        className="transition-transform"
      >
        {/* سهم صاعد عريض ومصمت مقترب (رفع / Upload) */}
        <g className={isPushing && isOnline && !uploadFaulted ? 'animate-pulse' : ''}>
          <line
            x1="8"
            y1="18.5"
            x2="8"
            y2="5.5"
            stroke={upColor}
            strokeWidth="2.8"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
          <polyline
            points="4,9.5 8,5.5 12,9.5"
            stroke={upColor}
            strokeWidth="2.8"
            strokeLinecap="round"
            strokeLinejoin="round"
            fill="none"
          />
        </g>

        {/* سهم هابط عريض ومصمت مقترب (سحب / Download) */}
        <g className={isPulling && isOnline && !downloadFaulted ? 'animate-pulse' : ''}>
          <line
            x1="16"
            y1="5.5"
            x2="16"
            y2="18.5"
            stroke={downColor}
            strokeWidth="2.8"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
          <polyline
            points="12,14.5 16,18.5 20,14.5"
            stroke={downColor}
            strokeWidth="2.8"
            strokeLinecap="round"
            strokeLinejoin="round"
            fill="none"
          />
        </g>
      </svg>

      {/* نقطة تنبيه صغيرة في حال وجود عمليات معلقة أو فشل */}
      {stats.failed > 0 ? (
        <span className="absolute -top-1 -right-1 w-2.5 h-2.5 rounded-full bg-rose-500 ring-2 ring-white"></span>
      ) : stats.pending > 0 ? (
        <span className="absolute -top-1 -right-1 w-2.5 h-2.5 rounded-full bg-amber-500 ring-2 ring-white animate-ping"></span>
      ) : null}
    </button>
  );
};
