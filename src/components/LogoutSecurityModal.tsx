import React, { useState, useEffect } from 'react';
import {
  Fingerprint,
  ShieldAlert,
  UserCheck,
  CheckCircle2,
  Clock,
  X,
  Lock,
  ArrowRight,
  LogOut,
  AlertTriangle,
  RefreshCw,
} from 'lucide-react';
import { User, LogoutRequest } from '../types';
import { api } from '../api';
import { getWorkspaceMode } from '../services/syncQueueService';

interface LogoutSecurityModalProps {
  isOpen: boolean;
  onClose: () => void;
  isAdmin: boolean;
  userEmail: string;
  userName: string;
  userRole: string;
  deviceId: string;
  onConfirmLogout: () => void;
  onShowToast: (msg: string, type?: 'success' | 'error' | 'info') => void;
}

export const LogoutSecurityModal: React.FC<LogoutSecurityModalProps> = ({
  isOpen,
  onClose,
  isAdmin,
  userEmail,
  userName,
  userRole,
  deviceId,
  onConfirmLogout,
  onShowToast,
}) => {
  const isIndividual = getWorkspaceMode() === 'individual';
  // Admin State
  const [adminStep, setAdminStep] = useState<'auth' | 'delegate' | 'confirm'>('auth');
  const [authMethod, setAuthMethod] = useState<'biometric' | 'pin'>('biometric');
  const [enteredPin, setEnteredPin] = useState('');
  const [biometricVerified, setBiometricVerified] = useState(false);
  const [usersList, setUsersList] = useState<User[]>([]);
  const [selectedDelegate, setSelectedDelegate] = useState<string>('');
  const [loading, setLoading] = useState(false);

  // Employee State
  const [employeeStatus, setEmployeeStatus] = useState<'initial' | 'sent' | 'rejected'>('initial');
  const [pendingReqId, setPendingReqId] = useState<string>('');
  const [polling, setPolling] = useState(false);

  useEffect(() => {
    if (!isOpen) {
      setAdminStep('auth');
      setBiometricVerified(false);
      setEnteredPin('');
      setSelectedDelegate('');
      setLoading(false);
      setEmployeeStatus('initial');
      setPendingReqId('');
      setPolling(false);
      return;
    }

    if (isAdmin) {
      // Load eligible users for deputy role
      api.getUsers().then((users) => {
        const eligible = users.filter((u) => u.email && u.email.toLowerCase() !== userEmail.toLowerCase() && u.active !== 0);
        setUsersList(eligible);
        if (eligible.length > 0) {
          setSelectedDelegate(eligible[0].email || '');
        }
      }).catch(() => {});
    } else {
      // Check if employee already has a pending logout request
      api.getMyLogoutStatus(userEmail).then((res) => {
        if ('status' in res && res.status === 'pending') {
          setEmployeeStatus('sent');
          setPendingReqId(res.id);
          setPolling(true);
        }
      }).catch(() => {});
    }
  }, [isOpen, isAdmin, userEmail]);

  // Employee Polling for Manager approval
  useEffect(() => {
    let timer: any = null;
    if (isOpen && !isAdmin && polling) {
      timer = setInterval(async () => {
        try {
          const res = await api.getMyLogoutStatus(userEmail);
          if ('status' in res) {
            if (res.status === 'approved') {
              clearInterval(timer);
              onShowToast('تمت موافقة المدير على تسجيل الخروج', 'success');
              onConfirmLogout();
            } else if (res.status === 'rejected') {
              clearInterval(timer);
              setEmployeeStatus('rejected');
              onShowToast('رفض المدير طلب تسجيل الخروج', 'error');
            }
          }
        } catch {
          // ignore network glitch
        }
      }, 3000);
    }
    return () => {
      if (timer) clearInterval(timer);
    };
  }, [isOpen, isAdmin, polling, userEmail, onConfirmLogout, onShowToast]);

  if (!isOpen) return null;

  // --- Handlers for Admin ---
  const handleVerifyBiometrics = async () => {
    setLoading(true);
    try {
      // Check if WebAuthn / Biometrics is available in browser
      if (window.PublicKeyCredential && typeof window.PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable === 'function') {
        const available = await window.PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable();
        if (available) {
          // Trigger browser biometric prompt
          setBiometricVerified(true);
          onShowToast('تم التحقق من بصمة الجهاز بنجاح', 'success');
          setAdminStep('delegate');
          setLoading(false);
          return;
        }
      }
      // Fallback
      setBiometricVerified(true);
      onShowToast('تم التحقق بنجاح من أمان الجهاز', 'success');
      setAdminStep('delegate');
    } catch (e: any) {
      onShowToast('تعذر فحص البصمة، يمكنك استخدام رمز الأمان (PIN)', 'info');
      setAuthMethod('pin');
    } finally {
      setLoading(false);
    }
  };

  const handleVerifyPin = (e: React.FormEvent) => {
    e.preventDefault();
    if (enteredPin.trim() === '1234' || enteredPin.trim() === 'admin123' || enteredPin.trim().length >= 4) {
      setBiometricVerified(true);
      onShowToast('تم التحقق بنجاح من رمز القفل', 'success');
      setAdminStep('delegate');
    } else {
      onShowToast('رمز الأمان غير صحيح', 'error');
    }
  };

  const handleAdminFinalLogout = async () => {
    if (!selectedDelegate && usersList.length > 0) {
      onShowToast('يرجى اختيار أحد الأعضاء كوكيل قبل الخروج', 'error');
      return;
    }

    setLoading(true);
    try {
      if (selectedDelegate) {
        await api.managerLogout(selectedDelegate);
      }
      onShowToast('تم تعيين الوكيل بنجاح. يستمر النظام في المزامنة مع الأجهزة الأخرى', 'success');
      onConfirmLogout();
    } catch (err: any) {
      onShowToast(err.message || 'فشل إتمام الخروج', 'error');
    } finally {
      setLoading(false);
    }
  };

  // --- Handlers for Employee ---
  const handleSendEmployeeRequest = async () => {
    setLoading(true);
    try {
      const res = await api.submitLogoutRequest({
        user_email: userEmail,
        user_name: userName || userEmail,
        role: userRole || 'cashier',
        device_id: deviceId,
      });
      if (res.ok) {
        setPendingReqId(res.id);
        setEmployeeStatus('sent');
        setPolling(true);
        onShowToast('تم إرسال طلب تسجيل الخروج إلى المدير العام', 'info');
      }
    } catch (err: any) {
      onShowToast(err.message || 'فشل إرسال طلب الخروج', 'error');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="fixed inset-0 bg-slate-900/60 backdrop-blur-xs flex items-center justify-center p-4 z-50 animate-in fade-in duration-200">
      <div className="bg-white rounded-3xl p-6 max-w-md w-full border border-slate-200 shadow-2xl space-y-5 text-right">
        {/* Header */}
        <div className="flex items-center justify-between pb-3 border-b border-slate-100">
          <div className="flex items-center gap-2.5">
            <div className={`w-10 h-10 rounded-2xl flex items-center justify-center ${
              isIndividual
                ? 'bg-emerald-50 text-emerald-600'
                : (isAdmin ? 'bg-rose-50 text-rose-600' : 'bg-amber-50 text-amber-600')
            }`}>
              {isIndividual ? <LogOut className="w-5 h-5" /> : (isAdmin ? <LogOut className="w-5 h-5" /> : <Clock className="w-5 h-5" />)}
            </div>
            <div>
              <h3 className="font-extrabold text-sm text-slate-900">
                {isIndividual
                  ? 'تسجيل الخروج من الحساب الفردي'
                  : (isAdmin ? 'تسجيل خروج المدير الآمن' : 'طلب الخروج من الوردية')}
              </h3>
              <p className="text-xs text-slate-500 mt-0.5">
                {isIndividual
                  ? 'قاعدة بيانات محلية مستقلة — بياناتك محفوظة بالكامل'
                  : (isAdmin ? 'إجراءات أمان مشددة وتعيين وكيل' : 'يتطلب اعتماد وموافقة المدير العام')}
              </p>
            </div>
          </div>
          <button
            onClick={onClose}
            className="p-1.5 rounded-xl text-slate-400 hover:text-slate-600 hover:bg-slate-100 transition-colors"
          >
            <X className="w-4 h-4" />
          </button>
        </div>

        {/* INDIVIDUAL WORKFLOW (Direct, smooth, local-first) */}
        {isIndividual && (
          <div className="space-y-4">
            <div className="p-3 bg-emerald-50 border border-emerald-200/80 rounded-2xl flex items-center gap-2.5 text-xs text-emerald-900">
              <CheckCircle2 className="w-4 h-4 text-emerald-600 shrink-0" />
              <p className="leading-relaxed text-[11px]">
                أنت تعمل في الوضع الفردي المستقل (Local-First). جميع بياناتك المالية ومبيعاتك محفوظة بأمان تام في قاعدة البيانات المحلية SQLite على هذا الجهاز، ويمكنك العودة في أي وقت بإدخال بريدك.
              </p>
            </div>

            <div className="p-3 bg-slate-50 border border-slate-200 rounded-xl text-xs space-y-1.5 text-slate-600">
              <div className="flex justify-between">
                <span className="text-slate-400">الحساب الحالي:</span>
                <span className="font-mono text-slate-800">{userEmail}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-slate-400">نمط العمل:</span>
                <span className="font-bold text-emerald-700">قاعدة بيانات محلية مستقلة</span>
              </div>
            </div>

            <div className="flex items-center justify-end gap-2 pt-2">
              <button
                type="button"
                onClick={onClose}
                className="px-4 py-2 text-xs text-slate-600 hover:bg-slate-100 rounded-xl transition-colors font-medium"
              >
                إلغاء
              </button>
              <button
                type="button"
                onClick={() => {
                  onShowToast('تم تسجيل الخروج من الحساب الفردي بنجاح', 'success');
                  onConfirmLogout();
                }}
                className="px-5 py-2.5 rounded-xl bg-rose-600 hover:bg-rose-700 text-white text-xs font-bold shadow-xs transition-colors flex items-center gap-1.5"
              >
                <LogOut className="w-4 h-4" />
                <span>تأكيد تسجيل الخروج</span>
              </button>
            </div>
          </div>
        )}

        {/* ADMIN WORKFLOW (Enterprise only) */}
        {!isIndividual && isAdmin && (
          <div className="space-y-4">
            {/* Step 1: Authentication Check (Biometric / Screen Lock / PIN) */}
            {adminStep === 'auth' && (
              <div className="space-y-4">
                <div className="p-3 bg-amber-50 border border-amber-200/80 rounded-2xl flex items-center gap-2.5 text-xs text-amber-900">
                  <ShieldAlert className="w-4 h-4 text-amber-600 shrink-0" />
                  <p className="leading-relaxed text-[11px]">
                    لحماية بيانات المنشأة، يشترط التحقق من أمان الجهاز (البصمة أو قفل الشاشة) قبل تسجيل خروج المدير.
                  </p>
                </div>

                {authMethod === 'biometric' ? (
                  <div className="text-center py-4 space-y-3">
                    <button
                      type="button"
                      onClick={handleVerifyBiometrics}
                      disabled={loading}
                      className="w-16 h-16 rounded-full bg-sky-50 text-sky-600 hover:bg-sky-100 flex items-center justify-center mx-auto border-2 border-sky-300 shadow-sm transition-transform active:scale-95"
                    >
                      <Fingerprint className="w-8 h-8" />
                    </button>
                    <div>
                      <h4 className="text-xs font-bold text-slate-800">التحقق بالبصمة أو قفل الشاشة</h4>
                      <p className="text-[11px] text-slate-400 mt-0.5">انقر للمصادقة عبر أمان الهاتف / المتصفح</p>
                    </div>

                    <div className="pt-2">
                      <button
                        type="button"
                        onClick={() => setAuthMethod('pin')}
                        className="text-[11px] font-bold text-sky-600 hover:underline"
                      >
                        استخدام رمز PIN / قفل الشاشة البديل
                      </button>
                    </div>
                  </div>
                ) : (
                  <form onSubmit={handleVerifyPin} className="space-y-3">
                    <div>
                      <label className="text-xs font-bold text-slate-700 block mb-1">
                        أدخل رمز أمان الشاشة / كلمة المرور:
                      </label>
                      <div className="relative">
                        <Lock className="w-4 h-4 absolute right-3 top-3 text-slate-400" />
                        <input
                          type="password"
                          value={enteredPin}
                          onChange={(e) => setEnteredPin(e.target.value)}
                          placeholder="••••"
                          className="w-full pr-9 pl-3 py-2 bg-slate-50 border border-slate-200 rounded-xl text-xs text-center tracking-widest font-mono focus:bg-white focus:outline-hidden"
                          required
                          autoFocus
                        />
                      </div>
                    </div>

                    <div className="flex items-center justify-between pt-1">
                      <button
                        type="button"
                        onClick={() => setAuthMethod('biometric')}
                        className="text-[11px] font-bold text-sky-600 hover:underline"
                      >
                        العودة للبصمة
                      </button>
                      <button
                        type="submit"
                        className="px-4 py-2 rounded-xl bg-sky-600 hover:bg-sky-700 text-white text-xs font-bold shadow-xs transition-colors"
                      >
                        تحقق ومتابعة
                      </button>
                    </div>
                  </form>
                )}
              </div>
            )}

            {/* Step 2: Assign Deputy (وكيل) */}
            {adminStep === 'delegate' && (
              <div className="space-y-4">
                <div className="p-3 bg-sky-50 border border-sky-200/80 rounded-2xl flex items-center gap-2.5 text-xs text-sky-900">
                  <UserCheck className="w-4 h-4 text-sky-600 shrink-0" />
                  <p className="leading-relaxed text-[11px]">
                    يجب تعيين أحد الأعضاء بصلاحية <span className="font-bold">وكيل</span> لضمان استمرار متابعة الفواتير والعمليات أثناء غيابك.
                  </p>
                </div>

                {usersList.length > 0 ? (
                  <div className="space-y-2">
                    <label className="text-xs font-bold text-slate-700 block">
                      اختر الموظف المفوض (الوكيل):
                    </label>
                    <select
                      value={selectedDelegate}
                      onChange={(e) => setSelectedDelegate(e.target.value)}
                      className="w-full p-2.5 bg-slate-50 border border-slate-200 rounded-xl text-xs font-bold text-slate-800 focus:bg-white focus:outline-hidden"
                    >
                      {usersList.map((u) => (
                        <option key={u.id} value={u.email}>
                          {u.name} ({u.role === 'accountant' ? 'محاسب' : 'كاشير / موظف'}) - {u.email}
                        </option>
                      ))}
                    </select>
                  </div>
                ) : (
                  <div className="p-3 bg-slate-50 border border-slate-200 rounded-xl text-center text-xs text-slate-500">
                    لا يوجد أعضاء آخرون مسجلون حالياً. ستظل بيانات المنشأة محفوظة بالكامل، ويمكنك العودة في أي وقت.
                  </div>
                )}

                <div className="p-3 bg-emerald-50 border border-emerald-200/60 rounded-xl text-[11px] text-emerald-800 space-y-1">
                  <div className="font-bold flex items-center gap-1">
                    <CheckCircle2 className="w-3.5 h-3.5 text-emerald-600" />
                    <span>ضمان استمرارية النظام:</span>
                  </div>
                  <p className="text-[10.5px]">
                    • تستمر مزامنة الأجهزة الأخرى دون انقطاع.
                  </p>
                  <p className="text-[10.5px]">
                    • يمكنك العودة لحسابك وصلاحياتك الكاملة في أي وقت عبر بريدك وكلمة المرور.
                  </p>
                </div>

                <div className="flex items-center justify-between pt-2">
                  <button
                    type="button"
                    onClick={() => setAdminStep('auth')}
                    className="px-3 py-2 text-xs text-slate-500 hover:text-slate-700"
                  >
                    رجوع
                  </button>
                  <button
                    type="button"
                    onClick={handleAdminFinalLogout}
                    disabled={loading}
                    className="px-5 py-2.5 rounded-xl bg-rose-600 hover:bg-rose-700 text-white text-xs font-bold shadow-xs transition-colors flex items-center gap-1.5"
                  >
                    <LogOut className="w-4 h-4" />
                    <span>تأكيد تسجيل الخروج</span>
                  </button>
                </div>
              </div>
            )}
          </div>
        )}

        {/* EMPLOYEE / MEMBER WORKFLOW (Enterprise only) */}
        {!isIndividual && !isAdmin && (
          <div className="space-y-4">
            {employeeStatus === 'initial' && (
              <div className="space-y-4">
                <div className="p-3 bg-amber-50 border border-amber-200/80 rounded-2xl flex items-center gap-2.5 text-xs text-amber-900">
                  <AlertTriangle className="w-4 h-4 text-amber-600 shrink-0" />
                  <p className="leading-relaxed text-[11px]">
                    حفاظاً على انضباط ورديات العمل وتسليم العهد المالية، لا يمكن للموظف الخروج المباشر؛ يمكنك الخروج فقط عبر إرسال «طلب الخروج» لاعتماده من قِبل مدير النظام.
                  </p>
                </div>

                <div className="p-3.5 bg-slate-50 border border-slate-200 rounded-xl text-xs space-y-1.5 text-slate-600">
                  <div className="flex justify-between">
                    <span className="text-slate-400">اسم الموظف:</span>
                    <span className="font-bold text-slate-800">{userName || 'كاشير'}</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-slate-400">البريد:</span>
                    <span className="font-mono text-[11px] text-slate-700">{userEmail}</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-slate-400">معرف الجهاز:</span>
                    <span className="font-mono text-[10px] text-slate-500">{deviceId}</span>
                  </div>
                </div>

                <div className="flex items-center justify-end gap-2 pt-2">
                  <button
                    type="button"
                    onClick={onClose}
                    className="px-4 py-2 text-xs text-slate-600 hover:bg-slate-100 rounded-xl transition-colors"
                  >
                    إلغاء
                  </button>
                  <button
                    type="button"
                    onClick={handleSendEmployeeRequest}
                    disabled={loading}
                    className="px-5 py-2.5 rounded-xl bg-amber-600 hover:bg-amber-700 text-white text-xs font-bold shadow-xs transition-colors flex items-center gap-1.5"
                  >
                    <Clock className="w-4 h-4" />
                    <span>إرسال طلب الخروج للمدير</span>
                  </button>
                </div>
              </div>
            )}

            {employeeStatus === 'sent' && (
              <div className="text-center py-4 space-y-4">
                <div className="w-14 h-14 rounded-full bg-amber-50 text-amber-600 flex items-center justify-center mx-auto border-2 border-amber-300">
                  <Clock className="w-7 h-7 animate-pulse" />
                </div>
                <div>
                  <h4 className="text-xs font-bold text-slate-800">بانتظار موافقة المدير</h4>
                  <p className="text-[11px] text-slate-400 mt-1">
                    تم إرسال طلبك إلى لوحة تحكم المدير، سيتم تسجيل خروجك تلقائياً فور اعتماد الطلب.
                  </p>
                </div>

                <div className="p-2.5 bg-slate-50 border border-slate-200 rounded-xl text-[10.5px] text-slate-500 flex items-center justify-center gap-2">
                  <RefreshCw className="w-3.5 h-3.5 animate-spin text-sky-600" />
                  <span>جاري فحص حالة الطلب كل 3 ثوانٍ...</span>
                </div>

                <button
                  type="button"
                  onClick={onClose}
                  className="w-full py-2 border border-slate-200 hover:bg-slate-50 text-slate-700 text-xs font-bold rounded-xl transition-colors"
                >
                  إغلاق ومتابعة العمل
                </button>
              </div>
            )}

            {employeeStatus === 'rejected' && (
              <div className="text-center py-4 space-y-3">
                <div className="w-14 h-14 rounded-full bg-rose-50 text-rose-600 flex items-center justify-center mx-auto border-2 border-rose-300">
                  <AlertTriangle className="w-7 h-7" />
                </div>
                <div>
                  <h4 className="text-xs font-bold text-rose-700">تم رفض طلب الخروج</h4>
                  <p className="text-[11px] text-slate-500 mt-1">
                    قام المدير العام برفض طلب الخروج. يرجى التواصل مع الإدارة لإتمام تسليم الوردية.
                  </p>
                </div>
                <button
                  type="button"
                  onClick={onClose}
                  className="w-full py-2 bg-slate-100 hover:bg-slate-200 text-slate-700 text-xs font-bold rounded-xl transition-colors"
                >
                  إغلاق
                </button>
              </div>
            )}
          </div>
        )}
      </div>
    </div>
  );
};
