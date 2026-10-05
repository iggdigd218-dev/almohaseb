import React, { useState, useEffect, useCallback } from 'react';
import { Sidebar } from './components/Sidebar';
import { Header } from './components/Header';
import { DashboardView } from './components/DashboardView';
import { PosView } from './components/PosView';
import { AccountsView } from './components/AccountsView';
import { TransactionsView } from './components/TransactionsView';
import { InventoryView } from './components/InventoryView';
import { VouchersView } from './components/VouchersView';
import { UsersView } from './components/UsersView';
import { ReportsView } from './components/ReportsView';
import { SettingsView } from './components/SettingsView';
import { BackupView } from './components/BackupView';
import { LoginModal } from './components/LoginModal';
import { WorkspaceModeModal } from './components/WorkspaceModeModal';
import { AccountStatementModal } from './components/AccountStatementModal';
import { WelcomeGuideModal } from './components/WelcomeGuideModal';
import { ChangelogModal } from './components/ChangelogModal';
import { LogoutSecurityModal } from './components/LogoutSecurityModal';
import { MarkedBottomNav } from './components/MarkedBottomNav';
import {
  AccountModal,
  TransactionModal,
  ItemModal,
  UserModal,
  VoucherModal,
} from './components/Modals';
import {
  Account,
  Transaction,
  Item,
  Voucher,
  User,
  DashboardData,
  AuthSession,
} from './types';
import { api } from './api';
import {
  startBackgroundSync,
  getAuthSession,
  setAuthSession,
  clearAuthSession,
  getWorkspaceMode,
  setWorkspaceMode,
} from './services/syncQueueService';
import { usePermissions } from './hooks/usePermissions';
import { Lock, UserX } from 'lucide-react';

interface Toast {
  id: string;
  message: string;
  type: 'success' | 'error' | 'info';
}

export function App() {
  const [currentScreen, setCurrentScreen] = useState<string>('dashboard');
  const [isLoading, setIsLoading] = useState(false);
  const initialSession = getAuthSession();
  const [authSession, setAuthSessionState] = useState<AuthSession>(initialSession);
  // (3.70.0 — Security) لا بريد شخصي مثبّت: الهوية من الجلسة الفعلية فقط.
  const [userEmail, setUserEmail] = useState<string>(initialSession.user_email || '');

  const { canViewReports, isAdmin, isActive } = usePermissions();

  // App Data State
  const [dashboardData, setDashboardData] = useState<DashboardData | null>(null);
  const [accounts, setAccounts] = useState<Account[]>([]);
  const [transactions, setTransactions] = useState<Transaction[]>([]);
  const [items, setItems] = useState<Item[]>([]);
  const [vouchers, setVouchers] = useState<Voucher[]>([]);
  const [users, setUsers] = useState<User[]>([]);

  // Modals
  const [isAccountModalOpen, setIsAccountModalOpen] = useState(false);
  const [editingAccount, setEditingAccount] = useState<Account | null>(null);

  const [isTxModalOpen, setIsTxModalOpen] = useState(false);
  const [txInitialAccountId, setTxInitialAccountId] = useState<number | undefined>(undefined);

  const [isItemModalOpen, setIsItemModalOpen] = useState(false);
  const [editingItem, setEditingItem] = useState<Item | null>(null);

  const [isUserModalOpen, setIsUserModalOpen] = useState(false);
  const [editingUser, setEditingUser] = useState<User | null>(null);

  const [isVoucherModalOpen, setIsVoucherModalOpen] = useState(false);
  const [isLoginModalOpen, setIsLoginModalOpen] = useState(false);
  const [isWorkspaceModalOpen, setIsWorkspaceModalOpen] = useState(false);
  const [pendingSession, setPendingSession] = useState<AuthSession | null>(null);
  const [statementAccount, setStatementAccount] = useState<Account | null>(null);
  const [isWelcomeGuideOpen, setIsWelcomeGuideOpen] = useState(false);
  const [isMobileDrawerOpen, setIsMobileDrawerOpen] = useState(false);
  const [isLogoutSecurityModalOpen, setIsLogoutSecurityModalOpen] = useState(false);
  const [isChangelogModalOpen, setIsChangelogModalOpen] = useState(false);
  const [expulsionNotice, setExpulsionNotice] = useState<string | null>(null);

  // Check and show version 3.85.1 changelog once
  useEffect(() => {
    const seen = localStorage.getItem('nexora_version_changelog_seen');
    if (seen !== '3.85.1') {
      setIsChangelogModalOpen(true);
      localStorage.setItem('nexora_version_changelog_seen', '3.85.1');
    }
  }, []);

  // Toasts
  const [toasts, setToasts] = useState<Toast[]>([]);

  const showToast = useCallback((message: string, type: 'success' | 'error' | 'info' = 'info') => {
    const id = Date.now().toString();
    setToasts((prev) => [...prev, { id, message, type }]);
    setTimeout(() => {
      setToasts((prev) => prev.filter((t) => t.id !== id));
    }, 3500);
  }, []);

  const loadAllData = useCallback(async () => {
    setIsLoading(true);
    try {
      const [
        dash,
        accs,
        txs,
        its,
        vchs,
        usrs,
      ] = await Promise.all([
        api.getDashboard().catch(() => null),
        api.getAccounts().catch(() => []),
        api.getTransactions().catch(() => []),
        api.getItems().catch(() => []),
        api.getVouchers().catch(() => []),
        api.getUsers().catch(() => []),
      ]);

      if (dash) setDashboardData(dash);
      setAccounts(accs);
      setTransactions(txs);
      setItems(its);
      setVouchers(vchs);
      setUsers(usrs);
    } catch (err: any) {
      console.error('Error fetching data:', err);
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    loadAllData();
  }, [loadAllData]);

  useEffect(() => {
    const stopSync = startBackgroundSync();

    const handleDeviceExpelled = (e: any) => {
      const reason = e?.detail?.message || 'تم إنهاء ارتباط هذا الجهاز بالمجموعة من قِبل إدارة المنشأة.';
      clearAuthSession();
      setWorkspaceMode('individual');
      setUserEmail('guest@local');
      setExpulsionNotice(reason);
      showToast('⚠️ تم طرد هذا الجهاز وفك ارتباطه بالمجموعة', 'error');
    };

    window.addEventListener('device-expelled', handleDeviceExpelled);

    // Periodic check for enterprise members
    const interval = setInterval(async () => {
      const sess = getAuthSession();
      const currentMode = getWorkspaceMode();
      if (currentMode === 'enterprise' && sess.role !== 'admin' && sess.user_email && sess.user_email !== 'guest@local') {
        try {
          const status = await api.checkDeviceStatus();
          if (status.expelled) {
            handleDeviceExpelled({ detail: { message: status.reason } });
          }
        } catch (err: any) {
          if (err.message && err.message.includes('DEVICE_EXPELLED')) {
            handleDeviceExpelled({ detail: { message: err.message } });
          }
        }
      }
    }, 6000);

    return () => {
      stopSync();
      window.removeEventListener('device-expelled', handleDeviceExpelled);
      clearInterval(interval);
    };
  }, []);

  const handleLogout = () => {
    setIsLogoutSecurityModalOpen(true);
  };

  const handleExecuteLogout = () => {
    clearAuthSession();
    setUserEmail('guest@local');
    setIsLogoutSecurityModalOpen(false);
    setIsLoginModalOpen(true);
    showToast('تم تسجيل الخروج بنجاح', 'info');
  };

  const getScreenTitle = () => {
    switch (currentScreen) {
      case 'dashboard':
        return 'لوحة التحكم والمؤشرات المالية';
      case 'pos':
        return 'نقطة البيع وإصدار الفواتير (POS)';
      case 'accounts':
        return 'إدارة الحسابات والعملاء والموردين';
      case 'transactions':
        return 'سجل العمليات المالية والقيود';
      case 'vouchers':
        return 'السندات والقيود المحاسبية';
      case 'inventory':
        return 'المخزون وإدارة الأصناف';
      case 'reports':
        return 'التقارير المالية والتحليلية';
      case 'users':
        return 'المستخدمون والصلاحيات';
      case 'settings':
        return 'إعدادات المنشأة والترويسة';
      case 'backup':
        return 'النسخ الاحتياطي ومراجعة الأنشطة';
      default:
        return 'سجل المبيعات والديون';
    }
  };

  if (!isActive && !isAdmin) {
    return (
      <div className="min-h-screen bg-slate-900 text-slate-100 flex items-center justify-center p-4 font-sans" dir="rtl">
        <div className="bg-white rounded-3xl p-8 max-w-md w-full text-slate-900 text-center shadow-2xl space-y-4">
          <div className="w-16 h-16 rounded-2xl bg-rose-50 text-rose-600 flex items-center justify-center mx-auto border border-rose-100">
            <Lock className="w-8 h-8" />
          </div>
          <h2 className="text-xl font-black text-slate-900">تم تعطيل هذا الحساب</h2>
          <p className="text-xs text-slate-500 leading-relaxed">
            تم تعطيل صلاحيات الدخول لهذا الحساب ({userEmail}) محلياً من قبل مدير النظام. يرجى مراجعة المسؤول لإعادة التفعيل.
          </p>
          <button
            onClick={handleLogout}
            className="w-full py-2.5 bg-slate-900 hover:bg-slate-800 text-white font-bold rounded-xl text-xs transition-colors"
          >
            تسجيل الخروج والتبديل لحساب آخر
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-slate-100 flex flex-row">
      {/* Toast Notifications */}
      <div className="fixed bottom-4 left-4 z-50 space-y-2 max-w-sm pointer-events-none">
        {toasts.map((toast) => (
          <div
            key={toast.id}
            className={`pointer-events-auto px-4 py-3 rounded-2xl shadow-xl border text-xs font-bold transition-all duration-300 transform translate-y-0 ${
              toast.type === 'success'
                ? 'bg-emerald-800 text-white border-emerald-700'
                : toast.type === 'error'
                ? 'bg-rose-800 text-white border-rose-700'
                : 'bg-slate-900 text-white border-slate-800'
            }`}
          >
            {toast.message}
          </div>
        ))}
      </div>

      {/* Main Sidebar */}
      <Sidebar
        currentScreen={currentScreen}
        onSelectScreen={setCurrentScreen}
        accountsCount={accounts.length}
        userEmail={userEmail}
        onLogout={handleLogout}
        onOpenChangelog={() => setIsChangelogModalOpen(true)}
      />

      {/* Content Area */}
      <div className="flex-1 flex flex-col min-w-0 h-screen overflow-y-auto">
        <Header
          title={getScreenTitle()}
          onRefresh={loadAllData}
          onOpenTxModal={() => {
            setTxInitialAccountId(undefined);
            setIsTxModalOpen(true);
          }}
          onOpenAccountModal={() => {
            setEditingAccount(null);
            setIsAccountModalOpen(true);
          }}
          onOpenHelpGuide={() => setIsWelcomeGuideOpen(true)}
          onOpenMobileMenu={() => setIsMobileDrawerOpen(true)}
          onOpenLogin={() => setIsLoginModalOpen(true)}
          isLoading={isLoading}
          onShowToast={showToast}
        />

        <main className="p-4 sm:p-6 pb-24 md:pb-6 flex-1 max-w-7xl w-full mx-auto">
          {currentScreen === 'dashboard' && (
            <DashboardView
              data={dashboardData}
              onSelectAccount={(accId) => {
                setCurrentScreen('accounts');
              }}
              onOpenTxModal={() => {
                setTxInitialAccountId(undefined);
                setIsTxModalOpen(true);
              }}
            />
          )}

          {currentScreen === 'pos' && (
            <PosView
              items={items}
              accounts={accounts}
              onRefreshItems={loadAllData}
              onShowToast={showToast}
            />
          )}

          {currentScreen === 'accounts' && (
            <AccountsView
              accounts={accounts}
              onRefresh={loadAllData}
              onOpenAccountModal={(acc) => {
                setEditingAccount(acc || null);
                setIsAccountModalOpen(true);
              }}
              onOpenTxModal={(accId) => {
                setTxInitialAccountId(accId);
                setIsTxModalOpen(true);
              }}
              onOpenStatement={(acc) => {
                setStatementAccount(acc);
              }}
              onShowToast={showToast}
            />
          )}

          {currentScreen === 'transactions' && (
            <TransactionsView
              transactions={transactions}
              accounts={accounts}
              onRefresh={loadAllData}
              onOpenTxModal={() => {
                setTxInitialAccountId(undefined);
                setIsTxModalOpen(true);
              }}
              onShowToast={showToast}
            />
          )}

          {currentScreen === 'vouchers' && (
            <VouchersView
              vouchers={vouchers}
              accounts={accounts}
              onRefresh={loadAllData}
              onOpenVoucherModal={() => setIsVoucherModalOpen(true)}
              onShowToast={showToast}
            />
          )}

          {currentScreen === 'inventory' && (
            <InventoryView
              items={items}
              onRefresh={loadAllData}
              onOpenItemModal={(item) => {
                setEditingItem(item || null);
                setIsItemModalOpen(true);
              }}
              onShowToast={showToast}
            />
          )}

          {currentScreen === 'reports' && (
            canViewReports ? (
              <ReportsView
                dashboard={dashboardData}
                accounts={accounts}
                items={items}
                transactions={transactions}
              />
            ) : (
              <div className="bg-white rounded-3xl p-8 border border-slate-200 text-center max-w-md mx-auto my-12 shadow-xs space-y-4">
                <div className="w-14 h-14 rounded-2xl bg-rose-50 text-rose-600 flex items-center justify-center mx-auto border border-rose-100">
                  <Lock className="w-7 h-7" />
                </div>
                <div>
                  <h3 className="font-black text-slate-900 text-base">غير مصرّح لك بالوصول إلى التقارير</h3>
                  <p className="text-xs text-slate-500 mt-1 leading-relaxed">
                    تم تقييد صلاحية استعراض التقارير المالية والإحصائيات لحسابك من قبل مدير النظام.
                  </p>
                </div>
                <button
                  onClick={() => setCurrentScreen('pos')}
                  className="px-5 py-2.5 bg-sky-600 hover:bg-sky-700 text-white font-bold rounded-xl text-xs transition-colors shadow-xs"
                >
                  الانتقال إلى نقطة البيع (POS)
                </button>
              </div>
            )
          )}

          {currentScreen === 'users' && (
            isAdmin ? (
              <UsersView
                users={users}
                onRefresh={loadAllData}
                onOpenUserModal={(usr) => {
                  setEditingUser(usr || null);
                  setIsUserModalOpen(true);
                }}
                onShowToast={showToast}
              />
            ) : (
              <div className="bg-white rounded-3xl p-8 border border-slate-200 text-center max-w-md mx-auto my-12 shadow-xs space-y-4">
                <div className="w-14 h-14 rounded-2xl bg-amber-50 text-amber-600 flex items-center justify-center mx-auto border border-amber-100">
                  <Lock className="w-7 h-7" />
                </div>
                <div>
                  <h3 className="font-black text-slate-900 text-base">إدارة الصلاحيات والموظفين</h3>
                  <p className="text-xs text-slate-500 mt-1 leading-relaxed">
                    هذه الصفحة مخصصة لمدير المنشأة حصراً لتعديل أذونات الموظفين.
                  </p>
                </div>
                <button
                  onClick={() => setCurrentScreen('dashboard')}
                  className="px-5 py-2.5 bg-slate-900 hover:bg-slate-800 text-white font-bold rounded-xl text-xs transition-colors shadow-xs"
                >
                  العودة للوحة التحكم
                </button>
              </div>
            )
          )}

          {currentScreen === 'settings' && (
            <SettingsView onShowToast={showToast} />
          )}

          {currentScreen === 'backup' && (
            <BackupView onShowToast={showToast} />
          )}
        </main>

        {/* الشريط السفلي المعلم للمعاملات والتنقل السريع في المعاينة الجانبية والأجهزة */}
        <MarkedBottomNav
          currentScreen={currentScreen}
          onSelectScreen={setCurrentScreen}
          onOpenTxModal={() => {
            setTxInitialAccountId(undefined);
            setIsTxModalOpen(true);
          }}
        />

        {/* درج القائمة الجانبية للشاشات المحمولة والمعاينة الجانبية */}
        {isMobileDrawerOpen && (
          <div className="fixed inset-0 z-50 md:hidden flex justify-start">
            <div
              className="fixed inset-0 bg-slate-900/60 backdrop-blur-xs transition-opacity"
              onClick={() => setIsMobileDrawerOpen(false)}
            />
            <div className="relative w-72 max-w-[85vw] bg-slate-900 text-white h-full z-10 shadow-2xl flex flex-col">
              <div className="p-3.5 border-b border-slate-800 flex items-center justify-between">
                <span className="font-bold text-sm text-sky-400">القائمة الرئيسية</span>
                <button
                  onClick={() => setIsMobileDrawerOpen(false)}
                  className="p-1.5 rounded-lg text-slate-400 hover:text-white hover:bg-slate-800"
                >
                  ✕
                </button>
              </div>
              <div className="flex-1 overflow-y-auto">
                <Sidebar
                  className="flex w-full bg-slate-900 text-slate-100 flex-col select-none h-full"
                  currentScreen={currentScreen}
                  onSelectScreen={(s) => {
                    setCurrentScreen(s);
                    setIsMobileDrawerOpen(false);
                  }}
                  accountsCount={accounts.length}
                  userEmail={userEmail}
                  onLogout={handleLogout}
                  onOpenChangelog={() => {
                    setIsMobileDrawerOpen(false);
                    setIsChangelogModalOpen(true);
                  }}
                />
              </div>
            </div>
          </div>
        )}
      </div>

      {/* Modals */}
      <AccountModal
        isOpen={isAccountModalOpen}
        account={editingAccount}
        onClose={() => setIsAccountModalOpen(false)}
        onSuccess={loadAllData}
        onShowToast={showToast}
      />

      <TransactionModal
        isOpen={isTxModalOpen}
        accounts={accounts}
        initialAccountId={txInitialAccountId}
        onClose={() => setIsTxModalOpen(false)}
        onSuccess={loadAllData}
        onShowToast={showToast}
      />

      <ItemModal
        isOpen={isItemModalOpen}
        item={editingItem}
        onClose={() => setIsItemModalOpen(false)}
        onSuccess={loadAllData}
        onShowToast={showToast}
      />

      <UserModal
        isOpen={isUserModalOpen}
        user={editingUser}
        onClose={() => setIsUserModalOpen(false)}
        onSuccess={loadAllData}
        onShowToast={showToast}
      />

      <VoucherModal
        isOpen={isVoucherModalOpen}
        accounts={accounts}
        onClose={() => setIsVoucherModalOpen(false)}
        onSuccess={loadAllData}
        onShowToast={showToast}
      />

      <LoginModal
        isOpen={isLoginModalOpen}
        onSuccess={(session) => {
          setPendingSession(session);
          setIsLoginModalOpen(false);
          setIsWorkspaceModalOpen(true);
        }}
        onClose={() => setIsLoginModalOpen(false)}
        onShowToast={showToast}
      />

      <WorkspaceModeModal
        isOpen={isWorkspaceModalOpen}
        userName={pendingSession?.user_name}
        userEmail={pendingSession?.user_email}
        initialMode={getWorkspaceMode()}
        initialStoreId={pendingSession?.store_id || 'store-main'}
        onConfirm={async (chosenMode, storeId) => {
          if (!pendingSession) return;
          setWorkspaceMode(chosenMode);
          const updatedSession: AuthSession = {
            ...pendingSession,
            mode: chosenMode,
            store_id: chosenMode === 'enterprise' ? storeId : 'store-local',
          };
          setAuthSession(updatedSession);
          setAuthSessionState(updatedSession);
          setUserEmail(updatedSession.user_email);

          try {
            await api.updateWorkspaceMode({
              mode: chosenMode,
              store_id: chosenMode === 'enterprise' ? storeId : 'store-local',
              user_email: updatedSession.user_email,
            });
          } catch (err) {
            console.warn('Workspace update note:', err);
          }

          setIsWorkspaceModalOpen(false);
          setPendingSession(null);
          showToast(
            chosenMode === 'individual'
              ? '✅ تم تفعيل نمط النشاط الفردي بنجاح — مرحباً بك'
              : '✅ تم تفعيل نمط المنشأة والمزامنة بنجاح — مرحباً بك',
            'success'
          );
          loadAllData();
        }}
      />

      <AccountStatementModal
        isOpen={Boolean(statementAccount)}
        account={statementAccount}
        transactions={transactions}
        onClose={() => setStatementAccount(null)}
        onShowToast={showToast}
      />

      <WelcomeGuideModal
        isOpen={isWelcomeGuideOpen}
        onClose={() => setIsWelcomeGuideOpen(false)}
        onNavigate={(screen) => setCurrentScreen(screen)}
      />

      <ChangelogModal
        isOpen={isChangelogModalOpen}
        onClose={() => setIsChangelogModalOpen(false)}
      />

      <LogoutSecurityModal
        isOpen={isLogoutSecurityModalOpen}
        onClose={() => setIsLogoutSecurityModalOpen(false)}
        isAdmin={isAdmin || authSession.role === 'admin'}
        userEmail={userEmail}
        userName={authSession.user_name || 'المدير'}
        userRole={authSession.role || (isAdmin ? 'admin' : 'staff')}
        deviceId={authSession.device_id || 'dev-pos-main'}
        onConfirmLogout={handleExecuteLogout}
        onShowToast={showToast}
      />

      {/* Member Expulsion Alert Dialog */}
      {expulsionNotice && (
        <div className="fixed inset-0 bg-slate-900/80 backdrop-blur-xs flex items-center justify-center p-4 z-50 animate-in fade-in" dir="rtl">
          <div className="bg-white rounded-3xl p-6 max-w-md w-full text-slate-900 text-center shadow-2xl space-y-4 border border-rose-200">
            <div className="w-16 h-16 rounded-2xl bg-rose-50 text-rose-600 flex items-center justify-center mx-auto border border-rose-100">
              <UserX className="w-8 h-8" />
            </div>
            <h2 className="text-lg font-black text-slate-900">تم إنهاء ارتباطك بالمجموعة</h2>
            <p className="text-xs text-slate-600 leading-relaxed">
              {expulsionNotice}
            </p>
            <div className="p-3 bg-slate-50 border border-slate-200 rounded-xl text-[11px] text-slate-500">
              تم فك ارتباط الجهاز بالمجموعة، وإيقاف المزامنة، ومسح بيانات الجلسة، والتحويل للوضع المستقل بنجاح.
            </div>
            <button
              onClick={() => {
                setExpulsionNotice(null);
                setIsLoginModalOpen(true);
              }}
              className="w-full py-2.5 bg-slate-900 hover:bg-slate-800 text-white font-bold rounded-xl text-xs transition-colors shadow-xs"
            >
              حسناً فهمت (العودة للدخول)
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
