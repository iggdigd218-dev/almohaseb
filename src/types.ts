export type AccountKind = 'customer' | 'supplier' | 'cash';

export interface Account {
  id: number;
  name: string;
  kind: AccountKind;
  opening_balance: number;
  currency: string;
  phone?: string;
  whatsapp?: string;
  address?: string;
  notes?: string;
  category?: string;
  credit_limit?: number;
  balance?: number;
  last_tx?: string;
  created_at: string;
  updated_at: string;
}

export type TransactionType = 'debit' | 'credit' | 'inflow' | 'outflow' | 'revenue' | 'expense';

export interface TransactionItem {
  id?: number;
  tx_id?: number;
  name: string;
  quantity: number;
  unit_price: number;
  total: number;
}

export interface Transaction {
  id: number;
  account_id?: number;
  account_name?: string;
  type: TransactionType;
  amount: number;
  currency: string;
  from_id?: number;
  to_id?: number;
  rate?: number;
  description?: string;
  reference?: string;
  notes?: string;
  date: string;
  created_at: string;
  updated_at: string;
  items?: TransactionItem[];
}

export interface Item {
  id: number;
  name: string;
  sku: string;
  buy_price: number;
  sell_price: number;
  quantity: number;
  min_quantity: number;
  category: string;
  unit?: string;
  created_at: string;
}

export type VoucherKind = 'receipt' | 'payment' | 'debit' | 'credit' | 'transfer';
export type VoucherStatus = 'draft' | 'posted' | 'cancelled';

export interface Voucher {
  id: number;
  number: string;
  kind: VoucherKind;
  account_id?: number;
  account_name?: string;
  amount: number;
  currency: string;
  statement: string;
  notes?: string;
  status: VoucherStatus;
  date: string;
  created_at: string;
  updated_at: string;
}

export type UserRole = 'admin' | 'agent' | 'accountant' | 'dataentry' | 'viewer';

export interface User {
  id: number;
  name: string;
  email?: string;
  password?: string;
  role: UserRole;
  pin?: string;
  permissions?: string;
  is_me?: number;
  active?: number;
  created_at: string;
}

export type SyncAction = 'INSERT' | 'UPDATE' | 'DELETE';
export type SyncQueueStatus = 'pending' | 'syncing' | 'synced' | 'failed';

export interface SyncQueueItem {
  queue_id: string;
  store_id: string;
  user_email: string;
  device_id: string;
  table_name: string;
  record_id: string;
  action: SyncAction;
  payload: string;
  timestamp: number;
  status: SyncQueueStatus;
}

export interface SyncQueueStats {
  total: number;
  pending: number;
  syncing: number;
  synced: number;
  failed: number;
  last_sync_timestamp?: number;
}

export interface AuthSession {
  user_email: string;
  store_id: string;
  device_id: string;
  user_name: string;
  role: string;
  logged_in_at: number;
  mode?: 'individual' | 'enterprise';
  is_owner?: number;
}

export interface UserPermission {
  user_email: string;
  store_id: string;
  role: string;
  can_discount: number; // 0 or 1
  can_delete_tx: number; // 0 or 1
  can_view_reports: number; // 0 or 1
  can_manage_items: number; // 0 or 1
  is_active: number; // 0 or 1
  updated_at: number;
}

export interface DashboardData {
  totalSales: number;
  totalDebts: number;
  totalCredits: number;
  accountsCount: number;
  lowStock: number;
  topDebtors: Array<{
    id: number;
    name: string;
    phone: string;
    balance: number;
  }>;
  recentTx: Array<Transaction>;
}

export interface ActivityItem {
  id: number;
  text: string;
  ref_type?: string;
  ref_id?: string;
  user_name?: string;
  created_at: string;
}

export type WorkspaceMode = 'individual' | 'enterprise';

export interface LogoutRequest {
  id: string;
  user_email: string;
  user_name: string;
  role: string;
  device_id: string;
  requested_at: number;
  status: 'pending' | 'approved' | 'rejected';
}

export interface AutoBackupConfig {
  enabled: boolean;
  frequency: '2hours' | 'daily';
  last_backup_at?: number;
  google_drive_connected: boolean;
  google_drive_email?: string;
  storage_quota_mb?: number;
}

export interface LicenseInfo {
  status: 'active' | 'trial' | 'expired';
  mode: WorkspaceMode;
  max_devices: number;
  active_devices_count: number;
  days_remaining: number;
  plan_name: string;
}
