import { v4 as uuidv4 } from 'uuid';
import { SyncQueueItem, SyncQueueStats, AuthSession, SyncAction } from '../types';

const AUTH_STORAGE_KEY = 'nexora_auth_session';
const DEVICE_STORAGE_KEY = 'nexora_device_id';

// (3.70.0 — Security) Default session is fail-closed: no hardcoded personal
// email and no implicit admin role. Admin rights come strictly from a real
// login (users.role === 'admin') and the user_permissions table.
const DEFAULT_SESSION: AuthSession = {
  user_email: '',
  store_id: 'store-main',
  device_id: 'DEV-WEB-MAIN',
  user_name: 'مستخدم الويب',
  role: 'staff',
  logged_in_at: Date.now(),
};

/**
 * Get or create persistent device ID
 */
export function getDeviceId(): string {
  if (typeof window === 'undefined') return 'DEV-SERVER';
  let devId = localStorage.getItem(DEVICE_STORAGE_KEY);
  if (!devId) {
    devId = 'DEV-' + uuidv4().substring(0, 8).toUpperCase();
    localStorage.setItem(DEVICE_STORAGE_KEY, devId);
  }
  return devId;
}

const WORKSPACE_MODE_KEY = 'nexora_workspace_mode';

export function getWorkspaceMode(): 'individual' | 'enterprise' {
  if (typeof window === 'undefined') return 'enterprise';
  return (localStorage.getItem(WORKSPACE_MODE_KEY) as 'individual' | 'enterprise') || 'enterprise';
}

export function setWorkspaceMode(mode: 'individual' | 'enterprise'): void {
  if (typeof window === 'undefined') return;
  localStorage.setItem(WORKSPACE_MODE_KEY, mode);
  notifyListeners();
}

/**
 * Get the current local authentication session
 */
export function getAuthSession(): AuthSession {
  if (typeof window === 'undefined') return DEFAULT_SESSION;
  try {
    const raw = localStorage.getItem(AUTH_STORAGE_KEY);
    if (raw) {
      const parsed = JSON.parse(raw);
      if (parsed && parsed.user_email) {
        return parsed;
      }
    }
  } catch {
    // ignore parse error
  }
  return { ...DEFAULT_SESSION, device_id: getDeviceId() };
}

/**
 * Save authentication session to local storage
 */
export function setAuthSession(session: AuthSession): void {
  if (typeof window === 'undefined') return;
  localStorage.setItem(AUTH_STORAGE_KEY, JSON.stringify(session));
  notifyListeners();
}

/**
 * Clear authentication session
 */
export function clearAuthSession(): void {
  if (typeof window === 'undefined') return;
  localStorage.removeItem(AUTH_STORAGE_KEY);
  notifyListeners();
}

type SyncListener = (stats: SyncQueueStats, isOnline: boolean, isSyncing: boolean) => void;
const listeners = new Set<SyncListener>();

let currentStats: SyncQueueStats = {
  total: 0,
  pending: 0,
  syncing: 0,
  synced: 0,
  failed: 0,
  last_sync_timestamp: 0,
};

let isCurrentlySyncing = false;
let isNetworkOnline = typeof navigator !== 'undefined' ? navigator.onLine : true;
let syncIntervalId: any = null;

function notifyListeners() {
  listeners.forEach((listener) => {
    try {
      listener({ ...currentStats }, isNetworkOnline, isCurrentlySyncing);
    } catch (e) {
      console.error('Error in sync listener:', e);
    }
  });
}

/**
 * Subscribe to sync queue status updates
 */
export function subscribeSyncStatus(listener: SyncListener): () => void {
  listeners.add(listener);
  listener({ ...currentStats }, isNetworkOnline, isCurrentlySyncing);
  return () => {
    listeners.delete(listener);
  };
}

/**
 * Retrieve current statistics of the SQLite sync queue
 */
export async function getSyncStats(): Promise<SyncQueueStats> {
  try {
    const res = await fetch('/api/sync-queue/stats');
    if (res.ok) {
      const data = await res.json();
      currentStats = {
        total: Number(data.total) || 0,
        pending: Number(data.pending) || 0,
        syncing: Number(data.syncing) || 0,
        synced: Number(data.synced) || 0,
        failed: Number(data.failed) || 0,
        last_sync_timestamp: Number(data.last_sync_timestamp) || 0,
      };
      notifyListeners();
      return currentStats;
    }
  } catch (err) {
    // Silent fail in background
  }
  return currentStats;
}

/**
 * Enqueue a mutation into the local SQLite sync_queue
 */
export async function enqueueSyncOperation(
  params: {
    table_name: string;
    record_id: string | number;
    action: SyncAction;
    payload: any;
    store_id?: string;
    user_email?: string;
    device_id?: string;
  }
): Promise<SyncQueueItem | null> {
  const session = getAuthSession();
  const queueItem: SyncQueueItem = {
    queue_id: uuidv4(),
    store_id: params.store_id || session.store_id || 'store-main',
    user_email: params.user_email || session.user_email || '',
    device_id: params.device_id || session.device_id || getDeviceId(),
    table_name: params.table_name,
    record_id: String(params.record_id),
    action: params.action,
    payload: typeof params.payload === 'string' ? params.payload : JSON.stringify(params.payload),
    timestamp: Date.now(),
    status: 'pending',
  };

  try {
    const res = await fetch('/api/sync-queue', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-store-id': queueItem.store_id,
        'x-user-email': queueItem.user_email,
        'x-device-id': queueItem.device_id,
      },
      body: JSON.stringify([queueItem]),
    });

    if (res.ok) {
      currentStats.pending += 1;
      currentStats.total += 1;
      notifyListeners();
      // Silently request processing in background
      setTimeout(() => {
        processSyncBatch().catch(() => {});
      }, 500);
      return queueItem;
    }
  } catch (e) {
    console.error('Failed to enqueue sync operation:', e);
  }
  return null;
}

/**
 * Process a batch of up to 20 pending items silently
 */
export async function processSyncBatch(): Promise<{ processed: number; remaining: number }> {
  const mode = getWorkspaceMode();
  if (mode === 'individual') {
    // Individual mode is 100% local-first on SQLite without any cloud sync waiting
    isCurrentlySyncing = false;
    notifyListeners();
    return { processed: 0, remaining: 0 };
  }

  if (isCurrentlySyncing) {
    return { processed: 0, remaining: currentStats.pending };
  }

  isNetworkOnline = typeof navigator !== 'undefined' ? navigator.onLine : true;
  if (!isNetworkOnline) {
    isCurrentlySyncing = false;
    notifyListeners();
    return { processed: 0, remaining: currentStats.pending };
  }

  const session = getAuthSession();
  if (!session || !session.store_id) {
    isCurrentlySyncing = false;
    return { processed: 0, remaining: currentStats.pending };
  }

  try {
    // 1. Fetch up to 20 pending records from local SQLite (with quick timeout)
    const pendingRes = await fetch('/api/sync-queue/pending?limit=20', {
      signal: AbortSignal.timeout(3000),
    });
    if (!pendingRes.ok) {
      return { processed: 0, remaining: currentStats.pending };
    }

    const items: SyncQueueItem[] = await pendingRes.json();
    if (!items || items.length === 0) {
      // Nothing to sync — keep UI calm and avoid triggering any sync spinners
      if (isCurrentlySyncing) {
        isCurrentlySyncing = false;
        notifyListeners();
      }
      return { processed: 0, remaining: 0 };
    }

    // Only activate sync indicator when there is actual work to sync
    isCurrentlySyncing = true;
    notifyListeners();

    // 2. Mark retrieved batch as syncing locally
    const queueIds = items.map((it) => it.queue_id);
    await fetch('/api/sync-queue/status', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ queue_ids: queueIds, status: 'syncing' }),
      signal: AbortSignal.timeout(3000),
    });

    // 3. Send batch (<= 20) to the store cloud sync endpoint
    const batchRes = await fetch(`/api/stores/${encodeURIComponent(session.store_id)}/sync-batch`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-store-id': session.store_id,
        'x-user-email': session.user_email,
        'x-device-id': session.device_id,
      },
      body: JSON.stringify({
        store_id: session.store_id,
        user_email: session.user_email,
        device_id: session.device_id,
        batch: items,
      }),
      signal: AbortSignal.timeout(4000),
    });

    if (!batchRes.ok) {
      // Revert batch to pending if cloud endpoint fails
      await fetch('/api/sync-queue/status', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ queue_ids: queueIds, status: 'pending' }),
      }).catch(() => {});
      throw new Error(`Sync batch rejected with status ${batchRes.status}`);
    }

    const batchData = await batchRes.json();
    const confirmedIds = (batchData.processed_ids as string[]) || queueIds;

    // 4. Update status locally to 'synced' upon confirmation
    await fetch('/api/sync-queue/status', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ queue_ids: confirmedIds, status: 'synced' }),
    }).catch(() => {});

    await getSyncStats();

    // If there might be more pending items, schedule next batch cleanly
    if (items.length === 20) {
      setTimeout(() => {
        processSyncBatch().catch(() => {});
      }, 300);
    }

    return { processed: confirmedIds.length, remaining: Math.max(0, currentStats.pending - confirmedIds.length) };
  } catch (err) {
    // Silent fail in background, never block the user
    console.warn('Silent sync batch note:', err);
    await getSyncStats().catch(() => {});
    return { processed: 0, remaining: currentStats.pending };
  } finally {
    isCurrentlySyncing = false;
    notifyListeners();
  }
}

/**
 * Manually trigger immediate sync in background
 */
export async function triggerImmediateSync(): Promise<void> {
  const mode = getWorkspaceMode();
  if (mode === 'individual') {
    return;
  }
  await processSyncBatch();
}

/**
 * Initialize and start the background silent sync worker
 * Runs completely isolated from the UI lifecycle
 */
export function startBackgroundSync(): () => void {
  const handleOnline = () => {
    isNetworkOnline = true;
    notifyListeners();
    processSyncBatch().catch(() => {});
  };

  const handleOffline = () => {
    isNetworkOnline = false;
    isCurrentlySyncing = false;
    notifyListeners();
  };

  if (typeof window !== 'undefined') {
    window.addEventListener('online', handleOnline);
    window.addEventListener('offline', handleOffline);
  }

  // Initial stats fetch without spinning
  getSyncStats().then((st) => {
    if (st && st.pending > 0 && getWorkspaceMode() === 'enterprise') {
      processSyncBatch().catch(() => {});
    }
  });

  // Periodic silent check every 15 seconds (only acts if items exist)
  if (syncIntervalId) clearInterval(syncIntervalId);
  syncIntervalId = setInterval(() => {
    if (getWorkspaceMode() === 'enterprise') {
      processSyncBatch().catch(() => {});
    }
  }, 15000);

  return () => {
    if (typeof window !== 'undefined') {
      window.removeEventListener('online', handleOnline);
      window.removeEventListener('offline', handleOffline);
    }
    if (syncIntervalId) {
      clearInterval(syncIntervalId);
      syncIntervalId = null;
    }
  };
}

export const syncQueueService = {
  getDeviceId,
  getAuthSession,
  setAuthSession,
  clearAuthSession,
  subscribeSyncStatus,
  getSyncStats,
  enqueueSyncOperation,
  processSyncBatch,
  triggerImmediateSync,
  startBackgroundSync,
};
