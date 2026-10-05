import React, { useState, useEffect } from 'react';
import {
  Shield,
  Mail,
  LogIn,
  UserPlus,
  KeyRound,
  CheckCircle2,
  Eye,
  EyeOff,
  X,
} from 'lucide-react';
import { api } from '../api';
import { setAuthSession, getDeviceId, getAuthSession } from '../services/syncQueueService';
import { AuthSession } from '../types';

interface LoginModalProps {
  isOpen: boolean;
  onSuccess: (session: AuthSession) => void;
  onClose: () => void;
  onShowToast: (msg: string, type?: 'success' | 'error' | 'info') => void;
}

export const LoginModal: React.FC<LoginModalProps> = ({
  isOpen,
  onSuccess,
  onClose,
  onShowToast,
}) => {
  const currentSession = getAuthSession();
  const [isRegisterMode, setIsRegisterMode] = useState(false);
  const [name, setName] = useState('');
  const [email, setEmail] = useState(currentSession?.user_email || 'monerqaid950@gmail.com');
  const [password, setPassword] = useState('admin123');
  const [showPassword, setShowPassword] = useState(false);
  const [loading, setLoading] = useState(false);
  const [googleLoading, setGoogleLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Close on Escape key
  useEffect(() => {
    if (!isOpen) return;
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        onClose();
      }
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [isOpen, onClose]);

  if (!isOpen) return null;

  const quickRoles = [
    { label: 'المدير العام', email: 'monerqaid950@gmail.com', pass: 'admin123' },
    { label: 'المحاسب', email: 'accountant@nexora.local', pass: 'admin123' },
    { label: 'الكاشير', email: 'cashier@nexora.local', pass: 'admin123' },
  ];

  const handleQuickSelect = (rEmail: string, rPass: string) => {
    setEmail(rEmail);
    setPassword(rPass);
    setIsRegisterMode(false);
    setError(null);
  };

  const handleGoogleSignIn = async () => {
    setError(null);
    setGoogleLoading(true);
    try {
      const deviceId = getDeviceId();
      const targetEmail = email.trim() || 'monerqaid950@gmail.com';
      const targetName = name.trim() || 'المدير الأساسي (Google)';

      const res = await api.loginWithGoogle({
        email: targetEmail.toLowerCase(),
        name: targetName,
        device_id: deviceId,
      });

      setAuthSession(res.session);
      onShowToast(`✅ تم التحقق عبر Google بنجاح: مرحباً ${res.session.user_name}`, 'success');
      onSuccess(res.session);
      onClose();
    } catch (err: any) {
      const errMsg = err?.message || 'تعذر تسجيل الدخول بـ Google، يرجى المحاولة بالبريد';
      setError(errMsg);
      onShowToast(errMsg, 'error');
    } finally {
      setGoogleLoading(false);
    }
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    setLoading(true);

    try {
      const deviceId = getDeviceId();
      if (isRegisterMode) {
        if (!name.trim()) {
          setError('يرجى إدخال اسم المستخدم');
          setLoading(false);
          return;
        }
        const res = await api.register({
          name: name.trim(),
          email: email.trim().toLowerCase(),
          password,
          device_id: deviceId,
          role: 'admin',
        });
        setAuthSession(res.session);
        onShowToast(`✅ تم إنشاء الحساب بنجاح: مرحباً ${res.session.user_name}`, 'success');
        onSuccess(res.session);
        onClose();
      } else {
        const res = await api.login({
          email: email.trim().toLowerCase(),
          password,
          device_id: deviceId,
        });
        setAuthSession(res.session);
        onShowToast(`✅ تم تسجيل الدخول بنجاح: مرحباً ${res.session.user_name}`, 'success');
        onSuccess(res.session);
        onClose();
      }
    } catch (err: any) {
      const errMsg = err?.message || 'فشل تسجيل الدخول، تحقق من البيانات المدخلة';
      setError(errMsg);
      onShowToast(errMsg, 'error');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div
      className="fixed inset-0 bg-slate-900/60 backdrop-blur-xs flex items-center justify-center p-4 z-50 animate-in fade-in"
      dir="rtl"
      onClick={(e) => {
        if (e.target === e.currentTarget && !loading && !googleLoading) {
          onClose();
        }
      }}
    >
      <div className="bg-white rounded-3xl p-6 max-w-md w-full border border-slate-200 shadow-2xl space-y-4 relative max-h-[92vh] overflow-y-auto">
        {/* Close Button */}
        <button
          type="button"
          onClick={onClose}
          className="absolute left-4 top-4 p-1.5 rounded-full text-slate-400 hover:text-slate-700 hover:bg-slate-100 transition-colors"
          title="إغلاق (Esc)"
        >
          <X className="w-5 h-5" />
        </button>

        {/* Header */}
        <div className="text-center space-y-1 pt-1">
          <div className="w-12 h-12 rounded-2xl bg-indigo-50 text-indigo-600 flex items-center justify-center mx-auto text-xl font-bold border border-indigo-100 shadow-xs">
            <Shield className="w-6 h-6 text-indigo-600" />
          </div>
          <h3 className="font-extrabold text-base text-slate-900">
            {isRegisterMode ? 'إنشاء حساب جديد للمدير' : 'تسجيل الدخول إلى النظام'}
          </h3>
          <p className="text-xs text-slate-500">
            تسجيل دخول فوري ومحمي مع صلاحيات سيادية كاملة لإدارة النظام
          </p>
        </div>

        {/* Manager Ownership Badge */}
        <div className="p-2.5 rounded-xl bg-indigo-50/70 border border-indigo-100/90 text-indigo-900 flex items-start gap-2 text-[11px] leading-relaxed">
          <CheckCircle2 className="w-4 h-4 text-indigo-600 shrink-0 mt-0.5" />
          <div>
            <strong>ضمان السيادة:</strong> يتم اعتماد هذا الجهاز فوراً كـ <strong>المدير الأساسي</strong> مع صلاحيات سيادية كاملة لإدارة الحسابات.
          </div>
        </div>

        {/* Quick Google Sign-In Button */}
        <button
          type="button"
          onClick={handleGoogleSignIn}
          disabled={googleLoading || loading}
          className="w-full py-2.5 px-4 rounded-xl border border-slate-300 hover:bg-slate-50 active:scale-98 text-slate-700 font-bold transition-all flex items-center justify-center gap-2.5 shadow-xs text-xs disabled:opacity-50"
        >
          {googleLoading ? (
            <span>جارٍ التحقق والدخول بواسطة Google...</span>
          ) : (
            <>
              {/* Google G Logo SVG */}
              <svg width="18" height="18" viewBox="0 0 24 24">
                <path
                  fill="#4285F4"
                  d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z"
                />
                <path
                  fill="#34A853"
                  d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z"
                />
                <path
                  fill="#FBBC05"
                  d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.06H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.94l2.85-2.22.81-.63z"
                />
                <path
                  fill="#EA4335"
                  d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.06l3.66 2.84c.87-2.6 3.3-4.52 6.16-4.52z"
                />
              </svg>
              <span>تسجيل الدخول السريع بحساب Google</span>
            </>
          )}
        </button>

        <div className="relative flex py-1 items-center">
          <div className="flex-grow border-t border-slate-200"></div>
          <span className="flex-shrink mx-2 text-[10px] text-slate-400 font-bold">أو بالبريد الإلكتروني</span>
          <div className="flex-grow border-t border-slate-200"></div>
        </div>

        {/* Quick fill chips for testing accounts */}
        {!isRegisterMode && (
          <div className="space-y-1">
            <span className="text-[10px] text-slate-400 block font-medium">حسابات تجريبية سريعة:</span>
            <div className="flex flex-wrap gap-1.5">
              {quickRoles.map((role) => (
                <button
                  key={role.label}
                  type="button"
                  onClick={() => handleQuickSelect(role.email, role.pass)}
                  className={`text-[10px] px-2 py-1 rounded-lg border transition-all ${
                    email === role.email
                      ? 'bg-indigo-50 border-indigo-300 text-indigo-700 font-bold'
                      : 'bg-slate-50 border-slate-200 text-slate-600 hover:bg-slate-100'
                  }`}
                >
                  {role.label}
                </button>
              ))}
            </div>
          </div>
        )}

        {error && (
          <div className="p-2.5 rounded-xl bg-rose-50 border border-rose-200 text-rose-700 text-xs font-medium text-center space-y-1">
            <div>{error}</div>
            {error.includes('غير مسجل') && (
              <button
                type="button"
                onClick={() => {
                  setIsRegisterMode(true);
                  setError(null);
                }}
                className="text-xs text-indigo-700 underline font-bold"
              >
                انقر هنا لإنشاء هذا الحساب الآن
              </button>
            )}
          </div>
        )}

        <form onSubmit={handleSubmit} className="space-y-3 text-xs">
          {isRegisterMode && (
            <div>
              <label className="font-bold text-slate-700 block mb-1">اسم المدير الكامل:</label>
              <input
                type="text"
                required
                value={name}
                onChange={(e) => setName(e.target.value)}
                placeholder="منير قايد"
                className="w-full px-3 py-2 bg-slate-50 border border-slate-200 rounded-xl focus:bg-white focus:outline-hidden text-slate-900"
              />
            </div>
          )}

          <div>
            <label className="font-bold text-slate-700 block mb-1">البريد الإلكتروني المعتمد للمدير:</label>
            <div className="relative">
              <input
                type="email"
                required
                dir="ltr"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                placeholder="manager@example.com"
                className="w-full px-3 py-2 pl-9 bg-slate-50 border border-slate-200 rounded-xl focus:bg-white focus:outline-hidden text-slate-900 font-mono text-xs text-left"
              />
              <Mail className="w-4 h-4 text-slate-400 absolute left-3 top-2.5 pointer-events-none" />
            </div>
          </div>

          <div>
            <label className="font-bold text-slate-700 block mb-1">كلمة المرور:</label>
            <div className="relative">
              <input
                type={showPassword ? 'text' : 'password'}
                required
                dir="ltr"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                placeholder="••••••••"
                className="w-full px-3 py-2 pl-16 pr-3 bg-slate-50 border border-slate-200 rounded-xl focus:bg-white focus:outline-hidden text-slate-900 font-mono text-xs text-left"
              />
              <div className="absolute left-3 top-2.5 flex items-center gap-1.5">
                <button
                  type="button"
                  onClick={() => setShowPassword(!showPassword)}
                  className="text-slate-400 hover:text-slate-600 focus:outline-hidden"
                  title={showPassword ? 'إخفاء كلمة المرور' : 'إظهار كلمة المرور'}
                >
                  {showPassword ? <EyeOff className="w-4 h-4" /> : <Eye className="w-4 h-4" />}
                </button>
                <KeyRound className="w-4 h-4 text-slate-400 pointer-events-none" />
              </div>
            </div>
            <p className="text-[10px] text-slate-400 mt-0.5">كلمة مرور الحساب الافتراضي: admin123</p>
          </div>

          <div className="pt-2 flex items-center gap-2">
            <button
              type="button"
              onClick={onClose}
              disabled={loading || googleLoading}
              className="w-1/2 py-2.5 px-4 rounded-xl border border-slate-200 hover:bg-slate-50 text-slate-700 font-bold transition-colors"
            >
              إلغاء
            </button>
            <button
              type="submit"
              disabled={loading || googleLoading}
              className="w-1/2 py-2.5 px-4 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-bold shadow-xs transition-colors flex items-center justify-center gap-2 disabled:opacity-50"
            >
              {loading ? (
                <span>جاري التحقق...</span>
              ) : isRegisterMode ? (
                <>
                  <UserPlus className="w-4 h-4" />
                  <span>تسجيل واعتماد</span>
                </>
              ) : (
                <>
                  <LogIn className="w-4 h-4" />
                  <span>دخول فوري</span>
                </>
              )}
            </button>
          </div>
        </form>

        <div className="pt-1 text-center">
          <button
            type="button"
            onClick={() => {
              setIsRegisterMode(!isRegisterMode);
              setError(null);
            }}
            className="text-indigo-600 hover:text-indigo-800 text-xs font-bold"
          >
            {isRegisterMode ? 'لديك حساب بالفعل؟ تسجيل الدخول' : 'إنشاء حساب جديد بالبريد الإلكتروني'}
          </button>
        </div>
      </div>
    </div>
  );
};
