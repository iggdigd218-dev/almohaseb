import { useState, useEffect, useCallback } from 'react';
import { UserPermission } from '../types';
import { api } from '../api';
import { getAuthSession } from '../services/syncQueueService';

const CACHE_KEY = 'nexora_my_permissions';

export interface UsePermissionsReturn {
  permissions: UserPermission | null;
  isAdmin: boolean;
  canDiscount: boolean;
  canDeleteTx: boolean;
  canViewReports: boolean;
  canManageItems: boolean;
  isActive: boolean;
  role: string;
  userEmail: string;
  loading: boolean;
  refresh: () => Promise<void>;
}

export function usePermissions(): UsePermissionsReturn {
  const [permissions, setPermissions] = useState<UserPermission | null>(() => {
    try {
      const cached = localStorage.getItem(CACHE_KEY);
      return cached ? JSON.parse(cached) : null;
    } catch {
      return null;
    }
  });
  const [loading, setLoading] = useState<boolean>(true);

  const session = getAuthSession();
  const currentEmail = (session?.user_email || '').toLowerCase();
  // (3.70.0 — Security) No hardcoded personal email anywhere: admin rights
  // derive strictly from the session role and the local SQLite
  // user_permissions table (served via /api), never from a literal address.
  const isSuperAdmin = session?.role === 'admin' || session?.mode === 'individual';

  const fetchPermissions = useCallback(async () => {
    try {
      const p = await api.getMyPermissions();
      if (p) {
        setPermissions((prev) => {
          if (prev && (prev.role !== p.role || prev.is_active !== p.is_active || prev.can_discount !== p.can_discount)) {
            // Role or capability changed in real-time
            window.dispatchEvent(new CustomEvent('permissions-updated'));
          }
          return p;
        });
        localStorage.setItem(CACHE_KEY, JSON.stringify(p));
      }
    } catch (err) {
      console.warn('Failed to load user permissions, using local fallback:', err);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchPermissions();

    const handleStorage = (e: StorageEvent) => {
      if (e.key === CACHE_KEY || e.key === 'nexora_auth_session') {
        fetchPermissions();
      }
    };

    const handleCustomEvent = () => {
      fetchPermissions();
    };

    // Real-time synchronization check every 5 seconds
    const intervalId = setInterval(() => {
      fetchPermissions();
    }, 5000);

    window.addEventListener('storage', handleStorage);
    window.addEventListener('permissions-updated', handleCustomEvent);
    window.addEventListener('auth-changed', handleCustomEvent);

    return () => {
      clearInterval(intervalId);
      window.removeEventListener('storage', handleStorage);
      window.removeEventListener('permissions-updated', handleCustomEvent);
      window.removeEventListener('auth-changed', handleCustomEvent);
    };
  }, [fetchPermissions]);

  const isAdmin = isSuperAdmin || permissions?.role === 'admin';
  const isActive = permissions ? Boolean(permissions.is_active) : true;

  // Super admins have all permissions by default; otherwise evaluate strict flags
  const canDiscount = isAdmin ? true : Boolean(permissions?.can_discount);
  const canDeleteTx = isAdmin ? true : Boolean(permissions?.can_delete_tx);
  const canViewReports = isAdmin ? true : Boolean(permissions?.can_view_reports);
  const canManageItems = isAdmin ? true : Boolean(permissions?.can_manage_items);
  const role = permissions?.role || session?.role || (isAdmin ? 'admin' : 'cashier');

  return {
    permissions,
    isAdmin,
    canDiscount,
    canDeleteTx,
    canViewReports,
    canManageItems,
    isActive,
    role,
    userEmail: currentEmail,
    loading,
    refresh: fetchPermissions,
  };
}
