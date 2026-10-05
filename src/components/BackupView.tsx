import React, { useState, useEffect, useRef } from 'react';
import { Database, Download, Upload, ShieldCheck, Clock, FileText, CheckCircle2, RefreshCw } from 'lucide-react';
import { ActivityItem } from '../types';
import { api } from '../api';
import { ConfirmModal } from './ConfirmModal';

interface BackupViewProps {
  onShowToast: (msg: string, type?: 'success' | 'error' | 'info') => void;
  onRefreshAll?: () => void;
}

export const BackupView: React.FC<BackupViewProps> = ({ onShowToast, onRefreshAll }) => {
  const [activities, setActivities] = useState<ActivityItem[]>([]);
  const [loading, setLoading] = useState(false);
  const [restoring, setRestoring] = useState(false);
  const [pendingBackupData, setPendingBackupData] = useState<any | null>(null);
  const [isConfirmRestoreOpen, setIsConfirmRestoreOpen] = useState(false);

  const fileInputRef = useRef<HTMLInputElement>(null);

  const loadActivity = () => {
    api.getActivity().then(setActivities).catch(() => {});
  };

  useEffect(() => {
    loadActivity();
  }, []);

  const handleExportBackup = async () => {
    setLoading(true);
    try {
      const data = await api.getBackup();
      const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = `nexora-backup-${new Date().toISOString().split('T')[0]}.json`;
      a.click();
      URL.revokeObjectURL(url);
      onShowToast('تم تصدير النسخة الاحتياطية بنجاح!', 'success');
      loadActivity();
    } catch (err: any) {
      onShowToast(err.message || 'فشل تصدير النسخة الاحتياطية', 'error');
    } finally {
      setLoading(false);
    }
  };

  const handleFileSelect = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;

    const reader = new FileReader();
    reader.onload = (evt) => {
      try {
        const json = JSON.parse(evt.target?.result as string);
        if (!json || typeof json !== 'object') {
          throw new Error('الملف لا يحتوي على بيانات JSON صالحة');
        }
        setPendingBackupData(json);
        setIsConfirmRestoreOpen(true);
      } catch (err: any) {
        onShowToast(err.message || 'فشل قراءة ملف النسخة الاحتياطية', 'error');
      }
    };
    reader.readAsText(file);
    // reset input so the same file can be selected again
    e.target.value = '';
  };

  const handleConfirmRestore = async () => {
    if (!pendingBackupData) return;
    setRestoring(true);
    try {
      const res = await api.restoreBackup(pendingBackupData);
      onShowToast(res.message || 'تمت استعادة النسخة الاحتياطية بنجاح!', 'success');
      setIsConfirmRestoreOpen(false);
      setPendingBackupData(null);
      loadActivity();
      if (onRefreshAll) onRefreshAll();
    } catch (err: any) {
      onShowToast(err.message || 'فشل استعادة النسخة الاحتياطية', 'error');
    } finally {
      setRestoring(false);
    }
  };

  const getRestoreSummary = () => {
    if (!pendingBackupData) return '';
    const accCount = Array.isArray(pendingBackupData.accounts) ? pendingBackupData.accounts.length : 0;
    const txCount = Array.isArray(pendingBackupData.transactions) ? pendingBackupData.transactions.length : 0;
    const itemCount = Array.isArray(pendingBackupData.items) ? pendingBackupData.items.length : 0;
    const vchCount = Array.isArray(pendingBackupData.vouchers) ? pendingBackupData.vouchers.length : 0;
    return `تحتوي هذه النسخة على: ${accCount} حساب، ${txCount} عملية مالية، ${itemCount} صنف، و ${vchCount} سند. هل تريد تأكيد استعادة البيانات وتحديث قاعدة البيانات بالكامل؟`;
  };

  return (
    <div className="space-y-6 text-right">
      <input
        type="file"
        ref={fileInputRef}
        onChange={handleFileSelect}
        accept=".json,application/json"
        className="hidden"
      />

      {/* Main Backup / Restore Controls */}
      <div className="bg-white rounded-2xl p-5 border border-slate-200 shadow-xs flex flex-col md:flex-row md:items-center justify-between gap-4">
        <div className="flex items-center gap-3">
          <div className="w-12 h-12 rounded-2xl bg-sky-100 text-sky-600 flex items-center justify-center shrink-0">
            <Database className="w-6 h-6" />
          </div>
          <div>
            <h3 className="font-extrabold text-sm text-slate-800">قاعدة البيانات والنسخ الاحتياطي</h3>
            <p className="text-xs text-slate-500 mt-0.5">
              قاعدة بيانات محلية تدعم التصدير والاستعادة الفورية للبيانات.
            </p>
          </div>
        </div>

        <div className="flex flex-wrap items-center gap-2.5 shrink-0">
          <button
            onClick={() => fileInputRef.current?.click()}
            disabled={restoring}
            className="flex items-center gap-1.5 px-4 py-2.5 rounded-xl border border-slate-200 hover:bg-slate-50 text-slate-700 text-xs font-bold shadow-xs transition-colors disabled:opacity-50"
          >
            <Upload className="w-4 h-4 text-slate-500" />
            <span>استعادة نسخة (JSON)</span>
          </button>

          <button
            onClick={handleExportBackup}
            disabled={loading}
            className="flex items-center gap-1.5 px-5 py-2.5 rounded-xl bg-sky-600 hover:bg-sky-700 text-white text-xs font-extrabold shadow-xs transition-colors disabled:opacity-50"
          >
            <Download className="w-4 h-4" />
            <span>تصدير نسخة (JSON)</span>
          </button>
        </div>
      </div>

      {/* Backup Information Cards */}
      <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
        <div className="p-4 bg-white rounded-2xl border border-slate-200 shadow-xs">
          <div className="flex items-center gap-2 text-emerald-600 font-bold text-xs">
            <ShieldCheck className="w-4 h-4" />
            <span>سلامة البيانات</span>
          </div>
          <p className="text-xs text-slate-600 mt-1.5 leading-relaxed">
            حفظ محلي آمن يضمن عدم فقدان أي حركة مالية.
          </p>
        </div>

        <div className="p-4 bg-white rounded-2xl border border-slate-200 shadow-xs">
          <div className="flex items-center gap-2 text-sky-600 font-bold text-xs">
            <RefreshCw className="w-4 h-4" />
            <span>تحديث فوري</span>
          </div>
          <p className="text-xs text-slate-600 mt-1.5 leading-relaxed">
            تحديث فوري للجداول والبيانات عند استعادة النسخة.
          </p>
        </div>

        <div className="p-4 bg-white rounded-2xl border border-slate-200 shadow-xs">
          <div className="flex items-center gap-2 text-purple-600 font-bold text-xs">
            <FileText className="w-4 h-4" />
            <span>أرشيف موحد</span>
          </div>
          <p className="text-xs text-slate-600 mt-1.5 leading-relaxed">
            ملف احتياطي قياسي لنقل البيانات بين الأجهزة بسهولة.
          </p>
        </div>
      </div>

      {/* Audit Trail / Activity Log */}
      <div className="bg-white rounded-2xl border border-slate-200 shadow-xs overflow-hidden">
        <div className="p-4 border-b border-slate-100 flex items-center justify-between">
          <div className="flex items-center gap-2">
            <Clock className="w-4 h-4 text-sky-600" />
            <h4 className="font-extrabold text-sm text-slate-800">سجل الأنشطة والعمليات الرقابية (Audit Log)</h4>
          </div>
          <span className="text-xs text-slate-400 font-mono">{activities.length} سجل</span>
        </div>

        <div className="divide-y divide-slate-100 max-h-96 overflow-y-auto">
          {activities.length === 0 ? (
            <div className="p-8 text-center text-slate-400 text-xs">
              لا توجد أنشطة مسجلة حتى الآن
            </div>
          ) : (
            activities.map((act) => (
              <div key={act.id} className="p-3.5 flex items-center justify-between text-xs hover:bg-slate-50 transition-colors">
                <div className="flex items-center gap-3">
                  <CheckCircle2 className="w-4 h-4 text-emerald-500 shrink-0" />
                  <div>
                    <span className="font-bold text-slate-800">{act.text}</span>
                    {act.user_name && (
                      <span className="text-[11px] text-slate-400 mr-2">بواسطة: {act.user_name}</span>
                    )}
                  </div>
                </div>
                <span className="text-[11px] text-slate-400 font-mono">
                  {new Date(act.created_at).toLocaleString('ar-YE')}
                </span>
              </div>
            ))
          )}
        </div>
      </div>

      {/* Confirmation Modal for Restore */}
      <ConfirmModal
        isOpen={isConfirmRestoreOpen}
        title="تأكيد استعادة النسخة الاحتياطية"
        message={getRestoreSummary()}
        confirmLabel="نعم، استعد النسخة الآن"
        cancelLabel="إلغاء"
        variant="warning"
        isLoading={restoring}
        onConfirm={handleConfirmRestore}
        onCancel={() => {
          setIsConfirmRestoreOpen(false);
          setPendingBackupData(null);
        }}
      />
    </div>
  );
};
