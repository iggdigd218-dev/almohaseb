import React, { useEffect, useState } from 'react';
import {
  LayoutDashboard,
  ShoppingCart,
  Users,
  CreditCard,
  Receipt,
  Package,
  BarChart3,
  UserCheck,
  Settings,
  Database,
  LogOut,
  ShieldCheck,
  RefreshCw,
  Cloud,
  CloudOff,
  CheckCircle2,
  Clock,
  Laptop,
  Sparkles,
  Store,
  User as UserIcon,
} from 'lucide-react';
import { subscribeSyncStatus, triggerImmediateSync, getAuthSession, getWorkspaceMode } from '../services/syncQueueService';
import { SyncQueueStats, AuthSession } from '../types';
import { usePermissions } from '../hooks/usePermissions';

interface NavItem {
  id: string;
  label: string;
  icon: React.ComponentType<{ className?: string }>;
  badge?: number;
}

interface NavSection {
  title: string;
  items: NavItem[];
}

interface SidebarProps {
  currentScreen: string;
  onSelectScreen: (screen: string) => void;
  accountsCount: number;
  userEmail: string;
  onLogout: () => void;
  onOpenChangelog?: () => void;
  className?: string;
}

export const Sidebar: React.FC<SidebarProps> = ({
  currentScreen,
  onSelectScreen,
  accountsCount,
  userEmail,
  onLogout,
  onOpenChangelog,
  className,
}) => {
  const [syncStats, setSyncStats] = useState<SyncQueueStats>({
    total: 0,
    pending: 0,
    syncing: 0,
    synced: 0,
    failed: 0,
    last_sync_timestamp: 0,
  });
  const [isOnline, setIsOnline] = useState(true);
  const [isSyncing, setIsSyncing] = useState(false);
  const [session, setSession] = useState<AuthSession>(getAuthSession());
  const [mode, setMode] = useState<'individual' | 'enterprise'>('enterprise');
  const { canViewReports, isAdmin, role } = usePermissions();

  useEffect(() => {
    setMode(getWorkspaceMode());
    const unsub = subscribeSyncStatus((stats, online, syncing) => {
      setSyncStats(stats);
      setIsOnline(online);
      setIsSyncing(syncing);
      setSession(getAuthSession());
      setMode(getWorkspaceMode());
    });
    return unsub;
  }, []);

  const handleManualSync = async () => {
    try {
      await triggerImmediateSync();
    } catch {}
  };

  const navSections: NavSection[] = [
    {
      title: 'الرئيسية',
      items: [
        { id: 'dashboard', label: 'لوحة التحكم', icon: LayoutDashboard },
        { id: 'pos', label: 'نقطة البيع (POS)', icon: ShoppingCart },
      ],
    },
    {
      title: 'الحسابات والعمليات',
      items: [
        { id: 'accounts', label: 'الحسابات والعملاء', icon: Users, badge: accountsCount },
        { id: 'transactions', label: 'العمليات المالية', icon: CreditCard },
        { id: 'vouchers', label: 'السندات والقيود', icon: Receipt },
      ],
    },
    {
      title: 'المخزون والتقارير',
      items: [
        { id: 'inventory', label: 'المخزون والأصناف', icon: Package },
        ...(canViewReports ? [{ id: 'reports', label: 'التقارير والإحصائيات', icon: BarChart3 }] : []),
      ],
    },
    {
      title: 'الإدارة والنظام',
      items: [
        ...(isAdmin ? [{ id: 'users', label: 'المستخدمون والصلاحيات', icon: UserCheck }] : []),
        { id: 'settings', label: mode === 'individual' ? 'إعدادات الحساب الفردي' : 'إعدادات المنشأة', icon: Settings },
        { id: 'backup', label: 'النسخ الاحتياطي للبيانات', icon: Database },
      ],
    },
  ];

  const showOwnerCircle = isAdmin || mode === 'individual';

  return (
    <aside className={className || "hidden md:flex w-72 bg-slate-900 text-slate-100 flex-col shrink-0 h-screen sticky top-0 border-l border-slate-800 shadow-xl select-none z-20"}>
      {/* Header / Brand Profile Section */}
      <div className="p-4 border-b border-slate-800 flex items-center justify-between gap-3">
        <div className="flex items-center gap-3 min-w-0">
          {showOwnerCircle ? (
            <div className="relative group cursor-pointer" onClick={() => onSelectScreen('settings')} title="إعدادات الحساب">
              <div className="w-10 h-10 rounded-full bg-gradient-to-tr from-sky-500 to-indigo-600 flex items-center justify-center text-sm shadow-lg shadow-sky-500/20 text-white font-extrabold ring-2 ring-sky-400/40">
                {(session?.store_id || 'N').charAt(0).toUpperCase()}
              </div>
              <div className="absolute -bottom-1 -left-1 w-4 h-4 rounded-full bg-emerald-500 border-2 border-slate-900 flex items-center justify-center text-[9px] text-white">
                ✓
              </div>
            </div>
          ) : (
            <div className="w-10 h-10 rounded-xl bg-slate-800 border border-slate-700 flex items-center justify-center text-sky-400 font-bold">
              <UserIcon className="w-5 h-5" />
            </div>
          )}

          <div className="min-w-0 flex-1">
            <div className="flex items-center gap-1.5 flex-wrap">
              <h1 className="font-extrabold text-xs text-white truncate max-w-[110px]">
                {showOwnerCircle ? (session?.store_id || 'متجر نكسورا') : 'نقطة بيع الموظف'}
              </h1>
              <span className={`px-1.5 py-0.5 rounded text-[9px] font-bold border shrink-0 ${
                mode === 'individual'
                  ? 'bg-emerald-950 text-emerald-300 border-emerald-800'
                  : (role === 'admin'
                      ? 'bg-purple-950 text-purple-300 border-purple-800'
                      : (role === 'accountant'
                          ? 'bg-emerald-950 text-emerald-300 border-emerald-800'
                          : (role === 'dataentry'
                              ? 'bg-amber-950 text-amber-300 border-amber-800'
                              : 'bg-sky-950 text-sky-300 border-sky-800')))
              }`}>
                {mode === 'individual'
                  ? 'حساب فردي'
                  : (role === 'admin'
                      ? 'مدير النظام'
                      : (role === 'accountant'
                          ? 'محاسب'
                          : (role === 'dataentry' ? 'مدخل بيانات' : 'كاشير')))}
              </span>
            </div>
            <p className="text-[11px] text-slate-400 truncate mt-0.5 font-mono" title={userEmail || session?.user_email}>
              {showOwnerCircle ? (userEmail || session?.user_email || '') : 'جلسة عمل نشطة'}
            </p>
          </div>
        </div>

        {isAdmin || mode === 'individual' ? (
          <button
            onClick={onLogout}
            className="p-1.5 rounded-lg text-slate-400 hover:text-rose-400 hover:bg-slate-800/80 transition-colors shrink-0"
            title="تسجيل الخروج الآمن"
          >
            <LogOut className="w-4 h-4" />
          </button>
        ) : (
          <button
            onClick={onLogout}
            className="flex items-center gap-1 px-2 py-1 rounded-lg text-amber-300 bg-amber-950/70 hover:bg-amber-900/80 border border-amber-700/80 transition-colors shrink-0 text-[10px] font-bold shadow-xs"
            title="طلب إذن الخروج من الوردية من المدير العام"
          >
            <Clock className="w-3.5 h-3.5 text-amber-400" />
            <span>طلب الخروج</span>
          </button>
        )}
      </div>

      {/* Session Context Banner */}
      <div className="px-3 py-1.5 bg-slate-950/40 border-b border-slate-800/60 text-[10px] flex items-center justify-between text-slate-400">
        <div className="flex items-center gap-1.5 truncate">
          <Laptop className="w-3 h-3 text-slate-500 shrink-0" />
          <span className="truncate font-mono" title={`الجهاز: ${session?.device_id}`}>
            {session?.device_id || 'DEV-LOCAL'}
          </span>
        </div>
        <span className="text-[9.5px] text-slate-400 font-medium">
          {mode === 'individual' ? 'قاعدة محلية مستقلة' : 'مزامنة المنشأة'}
        </span>
      </div>

      {/* Navigation list */}
      <div className="flex-1 overflow-y-auto px-3 py-3 space-y-4">
        {navSections.map((section, idx) => (
          <div key={idx}>
            <div className="text-[11px] font-bold text-slate-400 uppercase tracking-wider px-3 mb-1.5">
              {section.title}
            </div>
            <div className="space-y-0.5">
              {section.items.map((item) => {
                const Icon = item.icon;
                const active = currentScreen === item.id;
                return (
                  <button
                    key={item.id}
                    id={`nav-${item.id}`}
                    onClick={() => onSelectScreen(item.id)}
                    className={`w-full flex items-center gap-3 px-3 py-2 rounded-xl text-xs font-semibold transition-all duration-150 text-right ${
                      active
                        ? 'bg-sky-500 text-white shadow-md shadow-sky-500/25 font-bold'
                        : 'text-slate-300 hover:text-white hover:bg-slate-800/70'
                    }`}
                  >
                    <Icon className={`w-4 h-4 shrink-0 ${active ? 'text-white' : 'text-slate-400'}`} />
                    <span className="flex-1 truncate">{item.label}</span>
                    {typeof item.badge === 'number' && item.badge > 0 && (
                      <span
                        className={`text-[10px] px-2 py-0.5 rounded-full font-bold ${
                          active
                            ? 'bg-sky-700 text-white'
                            : 'bg-slate-800 text-slate-300'
                        }`}
                      >
                        {item.badge}
                      </span>
                    )}
                  </button>
                );
              })}
            </div>
          </div>
        ))}
      </div>

      {/* Offline-First Sync Queue Widget */}
      <div className="p-3 bg-slate-950/70 border-t border-slate-800/80 text-[11px] space-y-2 text-slate-400">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-1.5">
            {mode === 'individual' ? (
              <span className="flex items-center gap-1.5 text-sky-400 font-medium">
                <ShieldCheck className="w-3.5 h-3.5" />
                <span>تشغيل محلي بالكامل</span>
              </span>
            ) : isOnline ? (
              <span className="flex items-center gap-1.5 text-emerald-400 font-medium">
                <Cloud className="w-3.5 h-3.5" />
                <span>متصل بالشبكة</span>
              </span>
            ) : (
              <span className="flex items-center gap-1.5 text-amber-400 font-medium">
                <CloudOff className="w-3.5 h-3.5" />
                <span>دون اتصال (Offline)</span>
              </span>
            )}
          </div>
          {mode !== 'individual' && (
            <button
              onClick={handleManualSync}
              disabled={isSyncing || !isOnline}
              className="p-1 rounded-md text-slate-400 hover:text-white hover:bg-slate-800 disabled:opacity-40 transition-colors"
              title="مزامنة فورية"
            >
              <RefreshCw className={`w-3.5 h-3.5 ${isSyncing ? 'animate-spin text-sky-400' : ''}`} />
            </button>
          )}
        </div>

        {mode !== 'individual' && (
          <div className="flex items-center justify-between text-[10px] px-2 py-1.5 rounded-lg bg-slate-900 border border-slate-800">
            <div className="flex items-center gap-1">
              <Clock className="w-3 h-3 text-amber-400" />
              <span>طابور المزامنة:</span>
            </div>
            <div className="flex items-center gap-1 font-mono">
              {syncStats.pending > 0 ? (
                <span className="text-amber-400 font-bold px-1.5 py-0.2 rounded bg-amber-950/60 border border-amber-800/60">
                  {syncStats.pending} معلق
                </span>
              ) : (
                <span className="text-emerald-400 flex items-center gap-1">
                  <CheckCircle2 className="w-3 h-3" />
                  <span>مكتمل</span>
                </span>
              )}
            </div>
          </div>
        )}

        {/* Logout Button at bottom of sidebar */}
        <button
          id="btn-sidebar-logout"
          onClick={onLogout}
          className="w-full flex items-center justify-center gap-2 py-2 px-3 rounded-xl bg-rose-500/10 hover:bg-rose-500/20 text-rose-300 hover:text-rose-200 border border-rose-500/20 text-xs font-bold transition-all duration-150 active:scale-[0.98]"
        >
          <LogOut className="w-4 h-4 text-rose-400" />
          <span>{isAdmin ? 'تسجيل خروج المدير المحمي' : 'طلب تسجيل خروج الموظف'}</span>
        </button>

        {/* User-Facing Changelog & Version Trigger */}
        <div className="flex items-center justify-between text-[10px] text-slate-500 pt-0.5">
          <button
            type="button"
            onClick={onOpenChangelog}
            className="flex items-center gap-1 text-sky-400 hover:text-sky-300 transition-colors"
            title="عرض الجديد في التحديث"
          >
            <Sparkles className="w-3 h-3 text-sky-400" />
            <span>ما الجديد؟</span>
          </button>
          <span className="font-mono text-slate-400 font-bold">v3.85.1</span>
        </div>
      </div>
    </aside>
  );
};
