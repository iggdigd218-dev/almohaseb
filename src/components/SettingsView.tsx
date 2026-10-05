import React, { useState, useEffect } from 'react';
import {
  Settings,
  Save,
  Building,
  Phone,
  MapPin,
  DollarSign,
  Shield,
  Cloud,
  HardDrive,
  Clock,
  Sparkles,
  Laptop,
  CheckCircle2,
  RefreshCw,
} from 'lucide-react';
import { api } from '../api';
import { LicenseInfo } from '../types';
import { getWorkspaceMode, setWorkspaceMode } from '../services/syncQueueService';

interface SettingsViewProps {
  onShowToast: (msg: string, type?: 'success' | 'error' | 'info') => void;
}

export const SettingsView: React.FC<SettingsViewProps> = ({ onShowToast }) => {
  const [loading, setLoading] = useState(false);
  const [licenseInfo, setLicenseInfo] = useState<LicenseInfo | null>(null);
  const [currentMode, setCurrentMode] = useState<'individual' | 'enterprise'>('enterprise');
  const [backupInterval, setBackupInterval] = useState('daily');
  const [googleDriveEmail, setGoogleDriveEmail] = useState('');
  const [isSnapshotting, setIsSnapshotting] = useState(false);

  const [settings, setSettings] = useState({
    business_name: 'سجل المبيعات والديون',
    business_name_en: 'Nexora Ledger & POS',
    business_phone: '+967 770 000 000',
    business_address: 'صنعاء - الجمهورية اليمنية',
    currency: 'YER',
    workspaceMode: 'enterprise',
    backupInterval: 'daily',
    googleDriveEmail: '',
  });

  useEffect(() => {
    const localMode = getWorkspaceMode();
    setCurrentMode(localMode);

    api.getSettings().then((data) => {
      if (data && Object.keys(data).length > 0) {
        setSettings((prev) => ({ ...prev, ...data }));
        if (data.workspaceMode) {
          setCurrentMode(data.workspaceMode as any);
        }
        if (data.backupInterval) {
          setBackupInterval(data.backupInterval);
        }
        if (data.googleDriveEmail) {
          setGoogleDriveEmail(data.googleDriveEmail);
        }
      }
    });

    api.getLicenseInfo().then((info) => {
      setLicenseInfo(info);
    }).catch(() => {});
  }, []);

  const handleModeChange = (newMode: 'individual' | 'enterprise') => {
    setCurrentMode(newMode);
    setWorkspaceMode(newMode);
    setSettings((prev) => ({ ...prev, workspaceMode: newMode }));
    onShowToast(`تم تحويل نمط الحساب إلى ${newMode === 'individual' ? 'الحساب الفردي المحلي' : 'حساب المنشأة المتعدد الأجهزة'}`, 'info');
  };

  const handleTriggerSnapshot = async (googleDrive: boolean) => {
    setIsSnapshotting(true);
    try {
      await api.triggerAutoSnapshot({
        google_drive: googleDrive,
        email: googleDriveEmail || settings.googleDriveEmail,
      });
      onShowToast(
        googleDrive
          ? 'تم حفظ لقطة آمنة (Snapshot) إلى Google Drive بنجاح'
          : 'تم إنشاء نسخة احتياطية مجدولة محلياً بنجاح',
        'success'
      );
    } catch (err: any) {
      onShowToast(err.message || 'فشل حفظ النسخة الاحتياطية', 'error');
    } finally {
      setIsSnapshotting(false);
    }
  };

  const handleSave = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);
    try {
      const payload = {
        ...settings,
        workspaceMode: currentMode,
        backupInterval,
        googleDriveEmail,
      };
      await api.saveSettings(payload);
      setWorkspaceMode(currentMode);
      onShowToast('تم حفظ الإعدادات بنجاح', 'success');
    } catch (err: any) {
      onShowToast(err.message || 'فشل حفظ الإعدادات', 'error');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="max-w-2xl mx-auto space-y-6">
      {/* Header */}
      <div className="bg-white rounded-2xl p-4 border border-slate-200 shadow-xs flex items-center justify-between">
        <div>
          <h3 className="font-extrabold text-sm text-slate-800">
            {currentMode === 'individual' ? 'إعدادات الحساب الفردي' : 'إعدادات وبيانات المنشأة'}
          </h3>
          <p className="text-xs text-slate-400">تخصيص نمط التشغيل، النسخ الاحتياطي، وترويسة الفواتير</p>
        </div>
      </div>

      {/* Workspace Account Mode Selection */}
      <div className="bg-white rounded-2xl border border-slate-200 shadow-xs p-5 space-y-4">
        <div className="flex items-center gap-2">
          <Shield className="w-4 h-4 text-sky-600" />
          <h4 className="text-xs font-black text-slate-800">نمط الحساب وطبيعة التشغيل</h4>
        </div>

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
          {/* Individual Mode */}
          <button
            type="button"
            onClick={() => handleModeChange('individual')}
            className={`p-4 rounded-xl border text-right transition-all ${
              currentMode === 'individual'
                ? 'border-sky-500 bg-sky-50/60 shadow-xs ring-1 ring-sky-500'
                : 'border-slate-200 hover:bg-slate-50'
            }`}
          >
            <div className="flex items-center justify-between mb-2">
              <span className="font-black text-xs text-slate-800">حساب فردي (محلي مستقل)</span>
              {currentMode === 'individual' && <CheckCircle2 className="w-4 h-4 text-sky-600" />}
            </div>
            <p className="text-[11px] text-slate-500 leading-relaxed">
              تشغيل محلي بالكامل على SQLite بدون مزامنة شبكية، مع نسخ احتياطي مجدول وحفظ مجاني في Google Drive.
            </p>
          </button>

          {/* Enterprise Mode */}
          <button
            type="button"
            onClick={() => handleModeChange('enterprise')}
            className={`p-4 rounded-xl border text-right transition-all ${
              currentMode === 'enterprise'
                ? 'border-sky-500 bg-sky-50/60 shadow-xs ring-1 ring-sky-500'
                : 'border-slate-200 hover:bg-slate-50'
            }`}
          >
            <div className="flex items-center justify-between mb-2">
              <span className="font-black text-xs text-slate-800">حساب منشأة (مزامنة متعددة)</span>
              {currentMode === 'enterprise' && <CheckCircle2 className="w-4 h-4 text-sky-600" />}
            </div>
            <p className="text-[11px] text-slate-500 leading-relaxed">
              ربط ومزامنة عدة أجهزة ونقاط بيع، توزيع صلاحيات الموظفين، وإدارة الفروع.
            </p>
          </button>
        </div>

        {/* License & Device Quota Info */}
        {licenseInfo && (
          <div className="p-3 bg-slate-50 rounded-xl border border-slate-200/80 flex items-center justify-between text-xs text-slate-600">
            <div className="flex items-center gap-2">
              <Laptop className="w-4 h-4 text-slate-500" />
              <span>
                الأجهزة النشطة:{' '}
                <strong className="text-slate-900 font-mono">
                  {licenseInfo.active_devices_count} / {licenseInfo.max_devices}
                </strong>
              </span>
            </div>
            <span className="text-[11px] text-emerald-700 bg-emerald-50 border border-emerald-200 px-2 py-0.5 rounded-full font-bold">
              الخطة نشطة
            </span>
          </div>
        )}
      </div>

      {/* Scheduled Auto-Backup & Google Drive (Perpetual Free) */}
      <div className="bg-white rounded-2xl border border-slate-200 shadow-xs p-5 space-y-4">
        <div className="flex items-center gap-2">
          <Clock className="w-4 h-4 text-indigo-600" />
          <h4 className="text-xs font-black text-slate-800">النسخ الاحتياطي التلقائي والمجدول</h4>
        </div>

        <div className="space-y-3">
          <div>
            <label className="text-xs font-bold text-slate-700 block mb-1">تكرار الحفظ التلقائي (Snapshot):</label>
            <select
              value={backupInterval}
              onChange={(e) => setBackupInterval(e.target.value)}
              className="w-full p-2.5 bg-slate-50 border border-slate-200 rounded-xl text-xs font-bold focus:bg-white focus:outline-hidden"
            >
              <option value="2_hours">كل ساعتين تلقائياً</option>
              <option value="daily">يومياً (نهاية الوردية)</option>
              <option value="weekly">أسبوعياً</option>
            </select>
          </div>

          <div>
            <label className="text-xs font-bold text-slate-700 block mb-1">
              بريد Google Drive لحفظ اللقطات الاحتياطية (دائم ومجاني):
            </label>
            <input
              type="email"
              dir="ltr"
              value={googleDriveEmail}
              onChange={(e) => setGoogleDriveEmail(e.target.value)}
              placeholder="example@gmail.com"
              className="w-full px-3 py-2 bg-slate-50 border border-slate-200 rounded-xl text-xs focus:bg-white focus:outline-hidden"
            />
          </div>

          <div className="flex items-center gap-2 pt-1">
            <button
              type="button"
              onClick={() => handleTriggerSnapshot(false)}
              disabled={isSnapshotting}
              className="px-3.5 py-2 rounded-xl bg-slate-100 hover:bg-slate-200 text-slate-700 text-xs font-bold transition-colors"
            >
              حفظ لقطة محلية فورية
            </button>

            {googleDriveEmail && (
              <button
                type="button"
                onClick={() => handleTriggerSnapshot(true)}
                disabled={isSnapshotting}
                className="px-3.5 py-2 rounded-xl bg-indigo-50 hover:bg-indigo-100 text-indigo-700 text-xs font-bold transition-colors flex items-center gap-1.5"
              >
                <Cloud className="w-3.5 h-3.5" />
                <span>حفظ لقطة إلى Google Drive</span>
              </button>
            )}
          </div>
        </div>
      </div>

      {/* Main Settings Form */}
      <form onSubmit={handleSave} className="bg-white rounded-2xl border border-slate-200 shadow-xs p-6 space-y-4">
        <div>
          <label className="text-xs font-bold text-slate-700 block mb-1">اسم المنشأة / المحل (بالعربية):</label>
          <div className="relative">
            <Building className="w-4 h-4 absolute right-3 top-3 text-slate-400" />
            <input
              type="text"
              value={settings.business_name}
              onChange={(e) => setSettings({ ...settings, business_name: e.target.value })}
              className="w-full pr-9 pl-3 py-2 bg-slate-50 border border-slate-200 rounded-xl text-xs focus:bg-white focus:outline-hidden"
              required
            />
          </div>
        </div>

        <div>
          <label className="text-xs font-bold text-slate-700 block mb-1">اسم المنشأة بالإنجليزية (English):</label>
          <input
            type="text"
            dir="ltr"
            value={settings.business_name_en}
            onChange={(e) => setSettings({ ...settings, business_name_en: e.target.value })}
            className="w-full px-3 py-2 bg-slate-50 border border-slate-200 rounded-xl text-xs focus:bg-white focus:outline-hidden"
          />
        </div>

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <div>
            <label className="text-xs font-bold text-slate-700 block mb-1">رقم الهاتف / الواتساب:</label>
            <div className="relative">
              <Phone className="w-4 h-4 absolute right-3 top-3 text-slate-400" />
              <input
                type="text"
                dir="ltr"
                value={settings.business_phone}
                onChange={(e) => setSettings({ ...settings, business_phone: e.target.value })}
                className="w-full pr-9 pl-3 py-2 bg-slate-50 border border-slate-200 rounded-xl text-xs focus:bg-white focus:outline-hidden"
              />
            </div>
          </div>

          <div>
            <label className="text-xs font-bold text-slate-700 block mb-1">العملة الافتراضية:</label>
            <div className="relative">
              <DollarSign className="w-4 h-4 absolute right-3 top-3 text-slate-400" />
              <select
                value={settings.currency}
                onChange={(e) => setSettings({ ...settings, currency: e.target.value })}
                className="w-full pr-9 pl-3 py-2 bg-slate-50 border border-slate-200 rounded-xl text-xs font-bold focus:bg-white focus:outline-hidden"
              >
                <option value="YER">ريال يمني (YER)</option>
                <option value="SAR">ريال سعودي (SAR)</option>
                <option value="USD">دولار أمريكي (USD)</option>
                <option value="AED">درهم إماراتي (AED)</option>
              </select>
            </div>
          </div>
        </div>

        <div>
          <label className="text-xs font-bold text-slate-700 block mb-1">العنوان والموقع:</label>
          <div className="relative">
            <MapPin className="w-4 h-4 absolute right-3 top-3 text-slate-400" />
            <input
              type="text"
              value={settings.business_address}
              onChange={(e) => setSettings({ ...settings, business_address: e.target.value })}
              className="w-full pr-9 pl-3 py-2 bg-slate-50 border border-slate-200 rounded-xl text-xs focus:bg-white focus:outline-hidden"
            />
          </div>
        </div>

        <div className="pt-4 flex justify-end">
          <button
            type="submit"
            disabled={loading}
            className="flex items-center gap-2 px-6 py-2.5 rounded-xl bg-sky-600 hover:bg-sky-700 text-white text-xs font-extrabold shadow-sm transition-colors disabled:opacity-50"
          >
            <Save className="w-4 h-4" />
            <span>حفظ الإعدادات</span>
          </button>
        </div>
      </form>
    </div>
  );
};
