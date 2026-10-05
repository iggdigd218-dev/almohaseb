import React, { useState, useEffect, useCallback } from 'react';
import { 
  Shield, 
  Plus, 
  Edit2, 
  Trash2, 
  CheckCircle2, 
  XCircle, 
  Percent, 
  Trash, 
  BarChart3, 
  Package, 
  Mail, 
  UserCheck, 
  AlertCircle,
  RefreshCw,
  Lock,
  Sparkles,
  ToggleLeft,
  ToggleRight,
  UserX
} from 'lucide-react';
import { User, UserPermission, LogoutRequest } from '../types';
import { api } from '../api';
import { ConfirmModal } from './ConfirmModal';
import { getAuthSession } from '../services/syncQueueService';

interface UsersViewProps {
  users: User[];
  onRefresh: () => void;
  onOpenUserModal?: (user?: User) => void;
  onShowToast: (msg: string, type?: 'success' | 'error' | 'info') => void;
}

export const UsersView: React.FC<UsersViewProps> = ({
  users,
  onRefresh,
  onShowToast,
}) => {
  const [permissionsList, setPermissionsList] = useState<UserPermission[]>([]);
  const [logoutRequests, setLogoutRequests] = useState<LogoutRequest[]>([]);
  const [loading, setLoading] = useState(true);
  const [isModalOpen, setIsModalOpen] = useState(false);
  const [editingPermission, setEditingPermission] = useState<UserPermission | null>(null);
  const [deleteTarget, setDeleteTarget] = useState<UserPermission | null>(null);
  const [expelTarget, setExpelTarget] = useState<UserPermission | null>(null);
  const [isSaving, setIsSaving] = useState(false);
  const [isDeleting, setIsDeleting] = useState(false);
  const [isExpelling, setIsExpelling] = useState(false);

  // Form State
  const [formEmail, setFormEmail] = useState('');
  const [formRole, setFormRole] = useState<'cashier' | 'accountant' | 'admin' | 'dataentry'>('cashier');
  const [formCanDiscount, setFormCanDiscount] = useState(false);
  const [formCanDeleteTx, setFormCanDeleteTx] = useState(false);
  const [formCanViewReports, setFormCanViewReports] = useState(false);
  const [formCanManageItems, setFormCanManageItems] = useState(false);
  const [formIsActive, setFormIsActive] = useState(true);

  const session = getAuthSession();
  // (3.70.0 — Security) بلا بريد مثبّت: الهوية من الجلسة الفعلية فقط.
  const currentEmail = (session?.user_email || '').toLowerCase();

  const loadPermissions = useCallback(async () => {
    setLoading(true);
    try {
      const perms = await api.getUserPermissions();
      setPermissionsList(perms);
      const reqs = await api.getLogoutRequests();
      setLogoutRequests(reqs.filter((r) => r.status === 'pending'));
    } catch (err: any) {
      onShowToast(err.message || 'تعذر تحميل قائمة الصلاحيات', 'error');
    } finally {
      setLoading(false);
    }
  }, [onShowToast]);

  useEffect(() => {
    loadPermissions();
  }, [loadPermissions]);

  const handleRespondLogout = async (reqId: string, action: 'approved' | 'rejected') => {
    try {
      await api.respondLogoutRequest(reqId, action);
      onShowToast(action === 'approved' ? 'تمت الموافقة على خروج الموظف' : 'تم رفض طلب الخروج', 'info');
      setLogoutRequests((prev) => prev.filter((r) => r.id !== reqId));
    } catch (err: any) {
      onShowToast(err.message || 'فشل معالجة الطلب', 'error');
    }
  };

  const handleOpenModal = (perm?: UserPermission) => {
    if (perm) {
      setEditingPermission(perm);
      setFormEmail(perm.user_email);
      setFormRole((perm.role as any) || 'cashier');
      setFormCanDiscount(Boolean(perm.can_discount));
      setFormCanDeleteTx(Boolean(perm.can_delete_tx));
      setFormCanViewReports(Boolean(perm.can_view_reports));
      setFormCanManageItems(Boolean(perm.can_manage_items));
      setFormIsActive(perm.is_active !== 0);
    } else {
      setEditingPermission(null);
      setFormEmail('');
      setFormRole('cashier');
      // Default cashier: restricted
      setFormCanDiscount(false);
      setFormCanDeleteTx(false);
      setFormCanViewReports(false);
      setFormCanManageItems(false);
      setFormIsActive(true);
    }
    setIsModalOpen(true);
  };

  const handleRolePreset = (role: 'cashier' | 'accountant' | 'admin' | 'dataentry') => {
    setFormRole(role);
    if (role === 'admin') {
      setFormCanDiscount(true);
      setFormCanDeleteTx(true);
      setFormCanViewReports(true);
      setFormCanManageItems(true);
    } else if (role === 'accountant') {
      setFormCanDiscount(true);
      setFormCanDeleteTx(false);
      setFormCanViewReports(true);
      setFormCanManageItems(true);
    } else if (role === 'dataentry') {
      setFormCanDiscount(false);
      setFormCanDeleteTx(false);
      setFormCanViewReports(false);
      setFormCanManageItems(true);
    } else {
      // Cashier
      setFormCanDiscount(false);
      setFormCanDeleteTx(false);
      setFormCanViewReports(false);
      setFormCanManageItems(false);
    }
  };

  const handleSavePermission = async (e: React.FormEvent) => {
    e.preventDefault();
    const cleanEmail = formEmail.trim().toLowerCase();
    if (!cleanEmail) {
      onShowToast('يرجى إدخال البريد الإلكتروني للموظف', 'error');
      return;
    }

    setIsSaving(true);
    try {
      const payload: Partial<UserPermission> = {
        user_email: cleanEmail,
        store_id: session?.store_id || 'store-main',
        role: formRole,
        can_discount: formCanDiscount ? 1 : 0,
        can_delete_tx: formCanDeleteTx ? 1 : 0,
        can_view_reports: formCanViewReports ? 1 : 0,
        can_manage_items: formCanManageItems ? 1 : 0,
        is_active: formIsActive ? 1 : 0,
      };

      await api.saveUserPermissions(payload);
      onShowToast(
        editingPermission
          ? `تم تحديث صلاحيات "${cleanEmail}" بنجاح`
          : `تمت إضافة الموظف "${cleanEmail}" وتفعيل صلاحياته`,
        'success'
      );
      setIsModalOpen(false);
      await loadPermissions();
      onRefresh();
      window.dispatchEvent(new CustomEvent('permissions-updated'));
    } catch (err: any) {
      onShowToast(err.message || 'فشل حفظ الصلاحيات', 'error');
    } finally {
      setIsSaving(false);
    }
  };

  const handleToggleField = async (perm: UserPermission, field: keyof UserPermission) => {
    const isCurrentUser = perm.user_email.toLowerCase() === currentEmail;
    if (isCurrentUser && field === 'is_active') {
      onShowToast('لا يمكنك تعطيل حسابك الخاص', 'error');
      return;
    }

    const currentVal = perm[field];
    const newVal = currentVal ? 0 : 1;
    const updated = { ...perm, [field]: newVal };

    try {
      await api.updateUserPermissions(perm.user_email, { [field]: newVal });
      setPermissionsList((prev) =>
        prev.map((p) => (p.user_email === perm.user_email ? updated : p))
      );
      onShowToast(`تم تحديث الصلاحية بنجاح`, 'success');
      window.dispatchEvent(new CustomEvent('permissions-updated'));
    } catch (err: any) {
      onShowToast(err.message || 'تعذر تحديث الصلاحية', 'error');
    }
  };

  const handleConfirmDelete = async () => {
    if (!deleteTarget) return;
    setIsDeleting(true);
    try {
      await api.deleteUserPermissions(deleteTarget.user_email);
      onShowToast(`تم حذف صلاحيات "${deleteTarget.user_email}" بنجاح`, 'success');
      setDeleteTarget(null);
      await loadPermissions();
      window.dispatchEvent(new CustomEvent('permissions-updated'));
    } catch (err: any) {
      onShowToast(err.message || 'فشل الحذف', 'error');
    } finally {
      setIsDeleting(false);
    }
  };

  const handleConfirmExpel = async () => {
    if (!expelTarget) return;
    setIsExpelling(true);
    try {
      await api.expelUser(expelTarget.user_email);
      onShowToast(`تم طرد العضو "${expelTarget.user_email}" وفك ارتباط أجهزته نهائياً`, 'success');
      setExpelTarget(null);
      await loadPermissions();
      window.dispatchEvent(new CustomEvent('permissions-updated'));
    } catch (err: any) {
      onShowToast(err.message || 'فشل طرد العضو', 'error');
    } finally {
      setIsExpelling(false);
    }
  };

  const getRoleBadge = (role: string) => {
    switch (role) {
      case 'admin':
        return { label: 'مدير النظام (Admin)', class: 'bg-purple-50 text-purple-700 border-purple-200' };
      case 'accountant':
        return { label: 'محاسب (Accountant)', class: 'bg-emerald-50 text-emerald-700 border-emerald-200' };
      case 'dataentry':
        return { label: 'مدخل بيانات (Data Entry)', class: 'bg-amber-50 text-amber-700 border-amber-200' };
      case 'cashier':
      default:
        return { label: 'كاشير (Cashier)', class: 'bg-sky-50 text-sky-700 border-sky-200' };
    }
  };

  return (
    <div className="space-y-4">
      {/* Header Banner */}
      <div className="bg-white rounded-2xl p-4 border border-slate-200 shadow-xs flex flex-col sm:flex-row sm:items-center justify-between gap-3">
        <div>
          <div className="flex items-center gap-2">
            <div className="w-8 h-8 rounded-xl bg-sky-50 border border-sky-100 flex items-center justify-center text-sky-600">
              <Shield className="w-4 h-4" />
            </div>
            <div>
              <h3 className="font-black text-sm text-slate-900">نظام الصلاحيات والموظفين (RBAC)</h3>
              <p className="text-xs text-slate-500">
                إدارة أذونات الموظفين محلياً: الخصم، حذف العمليات، التقارير، وتعديل الأصناف
              </p>
            </div>
          </div>
        </div>

        <div className="flex items-center gap-2">
          <button
            onClick={loadPermissions}
            disabled={loading}
            className="p-2 text-slate-500 hover:text-slate-800 hover:bg-slate-100 rounded-xl transition-colors"
            title="تحديث البيانات"
          >
            <RefreshCw className={`w-4 h-4 ${loading ? 'animate-spin' : ''}`} />
          </button>

          <button
            id="btn-add-employee-permission"
            onClick={() => handleOpenModal()}
            className="flex items-center gap-1.5 px-3.5 py-2 text-xs font-bold bg-sky-600 hover:bg-sky-700 text-white rounded-xl shadow-xs transition-colors"
          >
            <Plus className="w-4 h-4" />
            <span>إضافة موظف جديد</span>
          </button>
        </div>
      </div>

      {/* Pending Logout Requests Banner (Manager Approval) */}
      {logoutRequests.length > 0 && (
        <div className="bg-amber-50/80 border border-amber-200/90 rounded-2xl p-4 space-y-3">
          <div className="flex items-center gap-2 text-amber-900 font-bold text-xs">
            <AlertCircle className="w-4 h-4 text-amber-600 shrink-0" />
            <span>طلبات تسجيل خروج الموظفين المعلقة ({logoutRequests.length}):</span>
          </div>

          <div className="grid grid-cols-1 md:grid-cols-2 gap-2.5">
            {logoutRequests.map((req) => (
              <div
                key={req.id}
                className="bg-white p-3 rounded-xl border border-amber-200 shadow-xs flex items-center justify-between gap-3 text-right"
              >
                <div>
                  <div className="text-xs font-bold text-slate-800">{req.user_name || req.user_email}</div>
                  <div className="text-[11px] text-slate-500 font-mono">{req.user_email}</div>
                  <div className="text-[10px] text-slate-400">
                    الدور: {req.role} • الجهاز: {req.device_id}
                  </div>
                </div>

                <div className="flex items-center gap-1.5 shrink-0">
                  <button
                    type="button"
                    onClick={() => handleRespondLogout(req.id, 'approved')}
                    className="px-2.5 py-1.5 bg-emerald-600 hover:bg-emerald-700 text-white rounded-lg text-xs font-bold transition-colors"
                  >
                    موافقة
                  </button>
                  <button
                    type="button"
                    onClick={() => handleRespondLogout(req.id, 'rejected')}
                    className="px-2.5 py-1.5 bg-rose-50 hover:bg-rose-100 text-rose-700 rounded-lg text-xs font-bold transition-colors"
                  >
                    رفض
                  </button>
                </div>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Permissions Summary Cards */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
        <div className="bg-white rounded-xl p-3 border border-slate-200 shadow-xs flex items-center gap-3">
          <div className="w-9 h-9 rounded-lg bg-sky-50 border border-sky-100 flex items-center justify-center text-sky-600 shrink-0">
            <UserCheck className="w-4 h-4" />
          </div>
          <div>
            <div className="text-[11px] text-slate-500 font-medium">إجمالي الموظفين</div>
            <div className="text-base font-black text-slate-900 font-mono">
              {permissionsList.length}
            </div>
          </div>
        </div>

        <div className="bg-white rounded-xl p-3 border border-slate-200 shadow-xs flex items-center gap-3">
          <div className="w-9 h-9 rounded-lg bg-emerald-50 border border-emerald-100 flex items-center justify-center text-emerald-600 shrink-0">
            <CheckCircle2 className="w-4 h-4" />
          </div>
          <div>
            <div className="text-[11px] text-slate-500 font-medium">الحسابات النشطة</div>
            <div className="text-base font-black text-emerald-600 font-mono">
              {permissionsList.filter((p) => p.is_active !== 0).length}
            </div>
          </div>
        </div>

        <div className="bg-white rounded-xl p-3 border border-slate-200 shadow-xs flex items-center gap-3">
          <div className="w-9 h-9 rounded-lg bg-purple-50 border border-purple-100 flex items-center justify-center text-purple-600 shrink-0">
            <Percent className="w-4 h-4" />
          </div>
          <div>
            <div className="text-[11px] text-slate-500 font-medium">مصرّح لهم بالخصم</div>
            <div className="text-base font-black text-purple-600 font-mono">
              {permissionsList.filter((p) => p.can_discount === 1 || p.role === 'admin').length}
            </div>
          </div>
        </div>

        <div className="bg-white rounded-xl p-3 border border-slate-200 shadow-xs flex items-center gap-3">
          <div className="w-9 h-9 rounded-lg bg-rose-50 border border-rose-100 flex items-center justify-center text-rose-600 shrink-0">
            <Trash className="w-4 h-4" />
          </div>
          <div>
            <div className="text-[11px] text-slate-500 font-medium">مصرّح لهم بالحذف</div>
            <div className="text-base font-black text-rose-600 font-mono">
              {permissionsList.filter((p) => p.can_delete_tx === 1 || p.role === 'admin').length}
            </div>
          </div>
        </div>
      </div>

      {/* Main Table */}
      <div className="bg-white rounded-2xl border border-slate-200 shadow-xs overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-right text-xs">
            <thead className="bg-slate-50/90 border-b border-slate-200 text-slate-500 font-bold">
              <tr>
                <th className="py-3.5 px-4">الموظف / البريد الإلكتروني</th>
                <th className="py-3.5 px-4">الدور الوظيفي</th>
                <th className="py-3.5 px-3 text-center">الخصم (POS)</th>
                <th className="py-3.5 px-3 text-center">حذف العمليات</th>
                <th className="py-3.5 px-3 text-center">عرض التقارير</th>
                <th className="py-3.5 px-3 text-center">إدارة الأصناف</th>
                <th className="py-3.5 px-3 text-center">حالة الحساب</th>
                <th className="py-3.5 px-4 text-left">إجراءات</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {permissionsList.length === 0 ? (
                <tr>
                  <td colSpan={8} className="py-10 text-center text-slate-400">
                    <Shield className="w-8 h-8 mx-auto mb-2 text-slate-300" />
                    <span>لا توجد سجلات صلاحيات مسجلة بعد. انقر على "إضافة موظف جديد" لإضافة الصلاحيات.</span>
                  </td>
                </tr>
              ) : (
                permissionsList.map((perm) => {
                  const badge = getRoleBadge(perm.role);
                  const isCurrent = perm.user_email.toLowerCase() === currentEmail;
                  const isAdminRole = perm.role === 'admin';

                  return (
                    <tr key={perm.user_email} className="hover:bg-slate-50/70 transition-colors">
                      {/* Email & Avatar */}
                      <td className="py-3.5 px-4">
                        <div className="flex items-center gap-2.5">
                          <div className="w-8 h-8 rounded-xl bg-slate-100 text-slate-700 flex items-center justify-center font-bold text-xs uppercase">
                            {perm.user_email.slice(0, 2)}
                          </div>
                          <div>
                            <div className="font-black text-slate-900 flex items-center gap-1.5 font-mono">
                              <span>{perm.user_email}</span>
                              {isCurrent && (
                                <span className="text-[10px] bg-emerald-100 text-emerald-800 px-1.5 py-0.2 rounded font-sans font-bold">
                                  أنت
                                </span>
                              )}
                            </div>
                            <div className="text-[10px] text-slate-400 font-mono">
                              {new Date(perm.updated_at).toLocaleDateString('ar-YE')}
                            </div>
                          </div>
                        </div>
                      </td>

                      {/* Role Badge */}
                      <td className="py-3.5 px-4">
                        <span className={`text-[10px] px-2.5 py-0.5 rounded-full font-bold border ${badge.class}`}>
                          {badge.label}
                        </span>
                      </td>

                      {/* can_discount */}
                      <td className="py-3.5 px-3 text-center">
                        <button
                          type="button"
                          onClick={() => handleToggleField(perm, 'can_discount')}
                          disabled={isAdminRole}
                          className={`inline-flex items-center justify-center w-7 h-7 rounded-lg transition-all ${
                            perm.can_discount || isAdminRole
                              ? 'bg-emerald-50 text-emerald-600 border border-emerald-200'
                              : 'bg-slate-100 text-slate-400 hover:bg-slate-200'
                          } ${isAdminRole ? 'cursor-not-allowed opacity-80' : 'cursor-pointer'}`}
                          title={isAdminRole ? 'مدير النظام يتمتع بكافة الصلاحيات تلقائياً' : 'تبديل صلاحية الخصم'}
                        >
                          {perm.can_discount || isAdminRole ? (
                            <CheckCircle2 className="w-4 h-4" />
                          ) : (
                            <XCircle className="w-4 h-4" />
                          )}
                        </button>
                      </td>

                      {/* can_delete_tx */}
                      <td className="py-3.5 px-3 text-center">
                        <button
                          type="button"
                          onClick={() => handleToggleField(perm, 'can_delete_tx')}
                          disabled={isAdminRole}
                          className={`inline-flex items-center justify-center w-7 h-7 rounded-lg transition-all ${
                            perm.can_delete_tx || isAdminRole
                              ? 'bg-rose-50 text-rose-600 border border-rose-200'
                              : 'bg-slate-100 text-slate-400 hover:bg-slate-200'
                          } ${isAdminRole ? 'cursor-not-allowed opacity-80' : 'cursor-pointer'}`}
                          title={isAdminRole ? 'مدير النظام يتمتع بكافة الصلاحيات تلقائياً' : 'تبديل صلاحية حذف العمليات'}
                        >
                          {perm.can_delete_tx || isAdminRole ? (
                            <CheckCircle2 className="w-4 h-4" />
                          ) : (
                            <XCircle className="w-4 h-4" />
                          )}
                        </button>
                      </td>

                      {/* can_view_reports */}
                      <td className="py-3.5 px-3 text-center">
                        <button
                          type="button"
                          onClick={() => handleToggleField(perm, 'can_view_reports')}
                          disabled={isAdminRole}
                          className={`inline-flex items-center justify-center w-7 h-7 rounded-lg transition-all ${
                            perm.can_view_reports || isAdminRole
                              ? 'bg-sky-50 text-sky-600 border border-sky-200'
                              : 'bg-slate-100 text-slate-400 hover:bg-slate-200'
                          } ${isAdminRole ? 'cursor-not-allowed opacity-80' : 'cursor-pointer'}`}
                          title={isAdminRole ? 'مدير النظام يتمتع بكافة الصلاحيات تلقائياً' : 'تبديل صلاحية التقارير'}
                        >
                          {perm.can_view_reports || isAdminRole ? (
                            <CheckCircle2 className="w-4 h-4" />
                          ) : (
                            <XCircle className="w-4 h-4" />
                          )}
                        </button>
                      </td>

                      {/* can_manage_items */}
                      <td className="py-3.5 px-3 text-center">
                        <button
                          type="button"
                          onClick={() => handleToggleField(perm, 'can_manage_items')}
                          disabled={isAdminRole}
                          className={`inline-flex items-center justify-center w-7 h-7 rounded-lg transition-all ${
                            perm.can_manage_items || isAdminRole
                              ? 'bg-amber-50 text-amber-600 border border-amber-200'
                              : 'bg-slate-100 text-slate-400 hover:bg-slate-200'
                          } ${isAdminRole ? 'cursor-not-allowed opacity-80' : 'cursor-pointer'}`}
                          title={isAdminRole ? 'مدير النظام يتمتع بكافة الصلاحيات تلقائياً' : 'تبديل صلاحية إدارة المخزون'}
                        >
                          {perm.can_manage_items || isAdminRole ? (
                            <CheckCircle2 className="w-4 h-4" />
                          ) : (
                            <XCircle className="w-4 h-4" />
                          )}
                        </button>
                      </td>

                      {/* is_active Toggle */}
                      <td className="py-3.5 px-3 text-center">
                        <button
                          type="button"
                          onClick={() => handleToggleField(perm, 'is_active')}
                          disabled={isCurrent}
                          className={`inline-flex items-center gap-1 px-2.5 py-1 rounded-full text-[10px] font-bold transition-colors ${
                            perm.is_active !== 0
                              ? 'bg-emerald-50 text-emerald-700 border border-emerald-200'
                              : 'bg-rose-50 text-rose-700 border border-rose-200'
                          } ${isCurrent ? 'opacity-60 cursor-not-allowed' : 'cursor-pointer'}`}
                        >
                          {perm.is_active !== 0 ? (
                            <>
                              <span className="w-1.5 h-1.5 rounded-full bg-emerald-500"></span>
                              <span>نشط</span>
                            </>
                          ) : (
                            <>
                              <span className="w-1.5 h-1.5 rounded-full bg-rose-500"></span>
                              <span>معطّل</span>
                            </>
                          )}
                        </button>
                      </td>

                      {/* Actions */}
                      <td className="py-3.5 px-4 text-left">
                        <div className="flex items-center justify-end gap-1">
                          <button
                            onClick={() => handleOpenModal(perm)}
                            className="p-1.5 rounded-lg text-slate-500 hover:text-slate-800 hover:bg-slate-100 transition-colors"
                            title="تعديل الصلاحيات بالكامل"
                          >
                            <Edit2 className="w-3.5 h-3.5" />
                          </button>

                          {!isAdminRole && !isCurrent && (
                            <>
                              <button
                                onClick={() => setExpelTarget(perm)}
                                className="p-1.5 rounded-lg text-rose-500 hover:text-white hover:bg-rose-600 transition-colors"
                                title="طرد العضو نهائياً وفك ارتباط كافة أجهزته بالمجموعة"
                              >
                                <UserX className="w-3.5 h-3.5" />
                              </button>
                              <button
                                onClick={() => setDeleteTarget(perm)}
                                className="p-1.5 rounded-lg text-slate-400 hover:text-rose-600 hover:bg-rose-50 transition-colors"
                                title="حذف الصلاحيات فقط"
                              >
                                <Trash2 className="w-3.5 h-3.5" />
                              </button>
                            </>
                          )}
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

      {/* Add / Edit Permission Modal */}
      {isModalOpen && (
        <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-slate-900/60 backdrop-blur-xs">
          <div className="bg-white rounded-3xl max-w-md w-full p-6 shadow-2xl border border-slate-100 space-y-4">
            <div className="flex items-center justify-between border-b border-slate-100 pb-3">
              <div className="flex items-center gap-2">
                <div className="w-8 h-8 rounded-xl bg-sky-50 text-sky-600 flex items-center justify-center">
                  <Shield className="w-4 h-4" />
                </div>
                <h3 className="font-black text-sm text-slate-900">
                  {editingPermission ? 'تعديل صلاحيات موظف' : 'إضافة موظف وتحديد الصلاحيات'}
                </h3>
              </div>
              <button
                onClick={() => setIsModalOpen(false)}
                className="text-slate-400 hover:text-slate-700 text-lg font-bold"
              >
                ✕
              </button>
            </div>

            <form onSubmit={handleSavePermission} className="space-y-4 text-xs">
              {/* Email */}
              <div className="space-y-1.5">
                <label className="font-bold text-slate-700 flex items-center gap-1.5">
                  <Mail className="w-3.5 h-3.5 text-slate-400" />
                  <span>البريد الإلكتروني للموظف</span>
                </label>
                <input
                  type="email"
                  required
                  value={formEmail}
                  onChange={(e) => setFormEmail(e.target.value)}
                  placeholder="employee@nexora.com"
                  disabled={Boolean(editingPermission)}
                  className="w-full py-2 px-3 bg-slate-50 border border-slate-200 rounded-xl font-mono text-xs focus:bg-white focus:outline-hidden disabled:bg-slate-100 disabled:text-slate-500"
                />
              </div>

              {/* Role Presets */}
              <div className="space-y-1.5">
                <label className="font-bold text-slate-700">الدور والنموذج الجاهز</label>
                <div className="grid grid-cols-2 sm:grid-cols-4 gap-1.5">
                  {(['cashier', 'accountant', 'dataentry', 'admin'] as const).map((r) => (
                    <button
                      key={r}
                      type="button"
                      onClick={() => handleRolePreset(r)}
                      className={`py-1.5 px-2 rounded-xl border text-[11px] font-bold transition-colors ${
                        formRole === r
                          ? 'bg-sky-50 border-sky-500 text-sky-700'
                          : 'bg-slate-50 border-slate-200 text-slate-600 hover:bg-slate-100'
                      }`}
                    >
                      {r === 'cashier'
                        ? 'كاشير'
                        : r === 'accountant'
                        ? 'محاسب'
                        : r === 'dataentry'
                        ? 'مدخل'
                        : 'مدير'}
                    </button>
                  ))}
                </div>
              </div>

              {/* Permission Switches */}
              <div className="space-y-2 pt-2 border-t border-slate-100">
                <div className="font-extrabold text-slate-800 text-[11px] mb-1">
                  أذونات الصلاحيات المفصلة:
                </div>

                {/* can_discount */}
                <label className="flex items-center justify-between p-2.5 rounded-xl border border-slate-200 bg-slate-50/60 hover:bg-slate-50 cursor-pointer transition-colors">
                  <div className="flex items-center gap-2">
                    <Percent className="w-4 h-4 text-purple-600" />
                    <div>
                      <div className="font-bold text-slate-800">تطبيق الخصم في نقطة البيع (POS)</div>
                      <div className="text-[10px] text-slate-400">السماح بتعديل حقل الخصم على الفواتير</div>
                    </div>
                  </div>
                  <input
                    type="checkbox"
                    checked={formCanDiscount}
                    onChange={(e) => setFormCanDiscount(e.target.checked)}
                    className="w-4 h-4 text-sky-600 rounded"
                  />
                </label>

                {/* can_delete_tx */}
                <label className="flex items-center justify-between p-2.5 rounded-xl border border-slate-200 bg-slate-50/60 hover:bg-slate-50 cursor-pointer transition-colors">
                  <div className="flex items-center gap-2">
                    <Trash className="w-4 h-4 text-rose-600" />
                    <div>
                      <div className="font-bold text-slate-800">حذف العمليات المالية</div>
                      <div className="text-[10px] text-slate-400">إظهار زر الحذف في جدول العمليات وحذف السجلات</div>
                    </div>
                  </div>
                  <input
                    type="checkbox"
                    checked={formCanDeleteTx}
                    onChange={(e) => setFormCanDeleteTx(e.target.checked)}
                    className="w-4 h-4 text-sky-600 rounded"
                  />
                </label>

                {/* can_view_reports */}
                <label className="flex items-center justify-between p-2.5 rounded-xl border border-slate-200 bg-slate-50/60 hover:bg-slate-50 cursor-pointer transition-colors">
                  <div className="flex items-center gap-2">
                    <BarChart3 className="w-4 h-4 text-sky-600" />
                    <div>
                      <div className="font-bold text-slate-800">استعراض التقارير والإحصائيات</div>
                      <div className="text-[10px] text-slate-400">السماح بفتح صفحة التقارير والاطلاع على الأرباح</div>
                    </div>
                  </div>
                  <input
                    type="checkbox"
                    checked={formCanViewReports}
                    onChange={(e) => setFormCanViewReports(e.target.checked)}
                    className="w-4 h-4 text-sky-600 rounded"
                  />
                </label>

                {/* can_manage_items */}
                <label className="flex items-center justify-between p-2.5 rounded-xl border border-slate-200 bg-slate-50/60 hover:bg-slate-50 cursor-pointer transition-colors">
                  <div className="flex items-center gap-2">
                    <Package className="w-4 h-4 text-amber-600" />
                    <div>
                      <div className="font-bold text-slate-800">إدارة المخزون وتعديل الأصناف</div>
                      <div className="text-[10px] text-slate-400">إضافة أصناف جديدة وتعديل أسعار الشراء والبيع</div>
                    </div>
                  </div>
                  <input
                    type="checkbox"
                    checked={formCanManageItems}
                    onChange={(e) => setFormCanManageItems(e.target.checked)}
                    className="w-4 h-4 text-sky-600 rounded"
                  />
                </label>

                {/* is_active */}
                <label className="flex items-center justify-between p-2.5 rounded-xl border border-slate-200 bg-slate-50/60 hover:bg-slate-50 cursor-pointer transition-colors">
                  <div className="flex items-center gap-2">
                    <CheckCircle2 className="w-4 h-4 text-emerald-600" />
                    <div>
                      <div className="font-bold text-slate-800">تفعيل حساب الموظف</div>
                      <div className="text-[10px] text-slate-400">تمكين الموظف من تسجيل الدخول والعمل على النظام</div>
                    </div>
                  </div>
                  <input
                    type="checkbox"
                    checked={formIsActive}
                    onChange={(e) => setFormIsActive(e.target.checked)}
                    className="w-4 h-4 text-sky-600 rounded"
                  />
                </label>
              </div>

              {/* Form Buttons */}
              <div className="flex justify-end gap-2 pt-3 border-t border-slate-100">
                <button
                  type="button"
                  onClick={() => setIsModalOpen(false)}
                  className="px-4 py-2 rounded-xl border border-slate-200 text-slate-600 font-bold hover:bg-slate-50"
                >
                  إلغاء
                </button>
                <button
                  type="submit"
                  disabled={isSaving}
                  className="px-5 py-2 rounded-xl bg-sky-600 hover:bg-sky-700 text-white font-bold transition-colors disabled:opacity-50"
                >
                  {isSaving ? 'جارٍ الحفظ...' : editingPermission ? 'حفظ التعديلات' : 'إضافة الموظف'}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {/* Confirm Delete Modal */}
      <ConfirmModal
        isOpen={Boolean(deleteTarget)}
        title="تأكيد حذف صلاحيات الموظف"
        message={`هل أنت متأكد من حذف صلاحيات "${deleteTarget?.user_email}" وإلغاء أذوناته من قاعدة البيانات المحلية؟`}
        confirmLabel="حذف الصلاحيات"
        cancelLabel="تراجع"
        variant="danger"
        isLoading={isDeleting}
        onConfirm={handleConfirmDelete}
        onCancel={() => setDeleteTarget(null)}
      />

      {/* Confirm Expel Modal */}
      <ConfirmModal
        isOpen={Boolean(expelTarget)}
        title="طرد العضو وفك ارتباطه بالمجموعة نهائياً"
        message={`تحذير: هل أنت متأكد من طرد العضو "${expelTarget?.user_email}" نهائياً من المجموعة؟ سيتم إخطار جهازه فوراً، وإلغاء ارتباط كافة أجهزته بالمجموعة، ومسح بيانات الجلسة وإعادته للوضع المستقل.`}
        confirmLabel="تأكيد طرد العضو وفك الارتباط"
        cancelLabel="إلغاء"
        variant="danger"
        isLoading={isExpelling}
        onConfirm={handleConfirmExpel}
        onCancel={() => setExpelTarget(null)}
      />
    </div>
  );
};
