import React, { useState, useEffect } from 'react';
import { X, Save, Plus } from 'lucide-react';
import { Account, Transaction, Item, User, Voucher, AccountKind, TransactionType, UserRole, VoucherKind } from '../types';
import { api } from '../api';

// ==========================================
// Account Modal
// ==========================================
interface AccountModalProps {
  isOpen: boolean;
  account?: Account | null;
  onClose: () => void;
  onSuccess: () => void;
  onShowToast: (msg: string, type?: 'success' | 'error' | 'info') => void;
}

export const AccountModal: React.FC<AccountModalProps> = ({
  isOpen,
  account,
  onClose,
  onSuccess,
  onShowToast,
}) => {
  const [name, setName] = useState('');
  const [kind, setKind] = useState<AccountKind>('customer');
  const [openingBalance, setOpeningBalance] = useState<number>(0);
  const [phone, setPhone] = useState('');
  const [whatsapp, setWhatsapp] = useState('');
  const [address, setAddress] = useState('');
  const [category, setCategory] = useState('');
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    if (account) {
      setName(account.name);
      setKind(account.kind);
      setOpeningBalance(account.opening_balance || 0);
      setPhone(account.phone || '');
      setWhatsapp(account.whatsapp || '');
      setAddress(account.address || '');
      setCategory(account.category || '');
    } else {
      setName('');
      setKind('customer');
      setOpeningBalance(0);
      setPhone('');
      setWhatsapp('');
      setAddress('');
      setCategory('');
    }
  }, [account, isOpen]);

  if (!isOpen) return null;

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!name.trim()) {
      onShowToast('الرجاء إدخال اسم الحساب', 'error');
      return;
    }

    setLoading(true);
    try {
      if (account) {
        await api.updateAccount(account.id, {
          name: name.trim(),
          kind,
          opening_balance: openingBalance,
          phone: phone.trim() || undefined,
          whatsapp: whatsapp.trim() || undefined,
          address: address.trim() || undefined,
          category: category.trim() || undefined,
        });
        onShowToast('تم تحديث الحساب بنجاح', 'success');
      } else {
        await api.createAccount({
          name: name.trim(),
          kind,
          opening_balance: openingBalance,
          currency: 'YER',
          phone: phone.trim() || undefined,
          whatsapp: whatsapp.trim() || undefined,
          address: address.trim() || undefined,
          category: category.trim() || undefined,
        });
        onShowToast('تم إضافة الحساب بنجاح', 'success');
      }
      onSuccess();
      onClose();
    } catch (err: any) {
      onShowToast(err.message || 'فشلت العملية', 'error');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="fixed inset-0 bg-slate-900/60 backdrop-blur-xs flex items-center justify-center p-4 z-50">
      <div className="bg-white rounded-3xl p-6 max-w-md w-full border border-slate-200 shadow-2xl space-y-4">
        <div className="flex items-center justify-between pb-3 border-b border-slate-100">
          <h3 className="font-black text-sm text-slate-900">
            {account ? 'تعديل بيانات الحساب' : 'إضافة حساب جديد'}
          </h3>
          <button onClick={onClose} className="p-1 rounded-lg text-slate-400 hover:text-slate-600">
            <X className="w-5 h-5" />
          </button>
        </div>

        <form onSubmit={handleSubmit} className="space-y-3 text-xs">
          <div>
            <label className="font-bold text-slate-700 block mb-1">اسم الحساب / العميل *</label>
            <input
              type="text"
              required
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="مثال: أحمد عبد الله"
              className="w-full px-3 py-2 bg-slate-50 border border-slate-200 rounded-xl focus:bg-white focus:outline-hidden"
            />
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="font-bold text-slate-700 block mb-1">نوع الحساب</label>
              <select
                value={kind}
                onChange={(e) => setKind(e.target.value as AccountKind)}
                className="w-full px-3 py-2 bg-slate-50 border border-slate-200 rounded-xl font-bold focus:bg-white focus:outline-hidden"
              >
                <option value="customer">عميل (Customer)</option>
                <option value="supplier">مورد (Supplier)</option>
                <option value="cash">صندوق نقدي (Cash)</option>
              </select>
            </div>

            <div>
              <label className="font-bold text-slate-700 block mb-1">الرصيد الافتتاحي</label>
              <input
                type="number"
                value={openingBalance}
                onChange={(e) => setOpeningBalance(Number(e.target.value) || 0)}
                placeholder="0"
                className="w-full px-3 py-2 bg-slate-50 border border-slate-200 rounded-xl font-mono focus:bg-white focus:outline-hidden"
              />
            </div>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="font-bold text-slate-700 block mb-1">رقم الهاتف</label>
              <input
                type="text"
                dir="ltr"
                value={phone}
                onChange={(e) => setPhone(e.target.value)}
                placeholder="770000000"
                className="w-full px-3 py-2 bg-slate-50 border border-slate-200 rounded-xl focus:bg-white focus:outline-hidden"
              />
            </div>

            <div>
              <label className="font-bold text-slate-700 block mb-1">رقم الواتساب</label>
              <input
                type="text"
                dir="ltr"
                value={whatsapp}
                onChange={(e) => setWhatsapp(e.target.value)}
                placeholder="770000000"
                className="w-full px-3 py-2 bg-slate-50 border border-slate-200 rounded-xl focus:bg-white focus:outline-hidden"
              />
            </div>
          </div>

          <div>
            <label className="font-bold text-slate-700 block mb-1">العنوان / المنطقة</label>
            <input
              type="text"
              value={address}
              onChange={(e) => setAddress(e.target.value)}
              placeholder="مثال: صنعاء - شارع تعز"
              className="w-full px-3 py-2 bg-slate-50 border border-slate-200 rounded-xl focus:bg-white focus:outline-hidden"
            />
          </div>

          <div>
            <label className="font-bold text-slate-700 block mb-1">الفئة / التصنيف</label>
            <input
              type="text"
              value={category}
              onChange={(e) => setCategory(e.target.value)}
              placeholder="مثال: جملة / تجزئة / VIP"
              className="w-full px-3 py-2 bg-slate-50 border border-slate-200 rounded-xl focus:bg-white focus:outline-hidden"
            />
          </div>

          <div className="flex justify-end gap-2 pt-3">
            <button
              type="button"
              onClick={onClose}
              className="px-4 py-2 rounded-xl text-slate-600 hover:bg-slate-100 font-bold"
            >
              إلغاء
            </button>
            <button
              type="submit"
              disabled={loading}
              className="px-5 py-2 rounded-xl bg-sky-600 hover:bg-sky-700 text-white font-bold shadow-xs disabled:opacity-50"
            >
              {loading ? 'جارٍ الحفظ...' : 'حفظ الحساب'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
};

// ==========================================
// Transaction Modal
// ==========================================
interface TransactionModalProps {
  isOpen: boolean;
  accounts: Account[];
  initialAccountId?: number;
  onClose: () => void;
  onSuccess: () => void;
  onShowToast: (msg: string, type?: 'success' | 'error' | 'info') => void;
}

export const TransactionModal: React.FC<TransactionModalProps> = ({
  isOpen,
  accounts,
  initialAccountId,
  onClose,
  onSuccess,
  onShowToast,
}) => {
  const [accountId, setAccountId] = useState<string>('');
  const [type, setType] = useState<TransactionType>('debit');
  const [amount, setAmount] = useState<number>(0);
  const [description, setDescription] = useState('');
  const [reference, setReference] = useState('');
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    if (initialAccountId) {
      setAccountId(String(initialAccountId));
    } else {
      setAccountId(accounts[0]?.id ? String(accounts[0].id) : '');
    }
    setType('debit');
    setAmount(0);
    setDescription('');
    setReference('');
  }, [isOpen, initialAccountId, accounts]);

  if (!isOpen) return null;

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!amount || amount <= 0) {
      onShowToast('الرجاء إدخال مبلغ صحيح', 'error');
      return;
    }

    setLoading(true);
    try {
      await api.createTransaction({
        account_id: accountId ? Number(accountId) : undefined,
        type,
        amount,
        currency: 'YER',
        description: description.trim() || undefined,
        reference: reference.trim() || undefined,
        date: new Date().toISOString(),
      });
      onShowToast('تم تسجيل العملية المالية بنجاح', 'success');
      onSuccess();
      onClose();
    } catch (err: any) {
      onShowToast(err.message || 'فشلت العملية', 'error');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="fixed inset-0 bg-slate-900/60 backdrop-blur-xs flex items-center justify-center p-4 z-50">
      <div className="bg-white rounded-3xl p-6 max-w-md w-full border border-slate-200 shadow-2xl space-y-4">
        <div className="flex items-center justify-between pb-3 border-b border-slate-100">
          <h3 className="font-black text-sm text-slate-900">تسجيل عملية مالية جديدة</h3>
          <button onClick={onClose} className="p-1 rounded-lg text-slate-400 hover:text-slate-600">
            <X className="w-5 h-5" />
          </button>
        </div>

        <form onSubmit={handleSubmit} className="space-y-3 text-xs">
          <div>
            <label className="font-bold text-slate-700 block mb-1">الحساب المعني</label>
            <select
              value={accountId}
              onChange={(e) => setAccountId(e.target.value)}
              className="w-full px-3 py-2 bg-slate-50 border border-slate-200 rounded-xl font-bold focus:bg-white focus:outline-hidden"
            >
              <option value="">-- بدون حساب (عملية عامة) --</option>
              {accounts.map((acc) => (
                <option key={acc.id} value={acc.id}>
                  {acc.name} ({acc.kind === 'customer' ? 'عميل' : acc.kind === 'supplier' ? 'مورد' : 'صندوق'})
                </option>
              ))}
            </select>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="font-bold text-slate-700 block mb-1">نوع العملية</label>
              <select
                value={type}
                onChange={(e) => setType(e.target.value as TransactionType)}
                className="w-full px-3 py-2 bg-slate-50 border border-slate-200 rounded-xl font-bold focus:bg-white focus:outline-hidden"
              >
                <option value="debit">عليه (مدين لنا) 🔴</option>
                <option value="credit">له (دائن علينا) 🟢</option>
                <option value="inflow">سند قبض (استلام نقد) 💵</option>
                <option value="outflow">سند صرف (دفع نقد) 💸</option>
                <option value="revenue">إيراد 📈</option>
                <option value="expense">مصروف 📉</option>
              </select>
            </div>

            <div>
              <label className="font-bold text-slate-700 block mb-1">المبلغ (ر.ي) *</label>
              <input
                type="number"
                min="1"
                required
                value={amount || ''}
                onChange={(e) => setAmount(Number(e.target.value) || 0)}
                placeholder="0"
                className="w-full px-3 py-2 bg-slate-50 border border-slate-200 rounded-xl font-mono text-sm font-bold focus:bg-white focus:outline-hidden"
              />
            </div>
          </div>

          <div>
            <label className="font-bold text-slate-700 block mb-1">البيان / الوصف</label>
            <input
              type="text"
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              placeholder="مثال: دفعة من حساب بضاعة / سداد نقد"
              className="w-full px-3 py-2 bg-slate-50 border border-slate-200 rounded-xl focus:bg-white focus:outline-hidden"
            />
          </div>

          <div>
            <label className="font-bold text-slate-700 block mb-1">رقم المرجع / الفاتورة (اختياري)</label>
            <input
              type="text"
              value={reference}
              onChange={(e) => setReference(e.target.value)}
              placeholder="مثال: INV-1049"
              className="w-full px-3 py-2 font-mono bg-slate-50 border border-slate-200 rounded-xl focus:bg-white focus:outline-hidden"
            />
          </div>

          <div className="flex justify-end gap-2 pt-3">
            <button
              type="button"
              onClick={onClose}
              className="px-4 py-2 rounded-xl text-slate-600 hover:bg-slate-100 font-bold"
            >
              إلغاء
            </button>
            <button
              type="submit"
              disabled={loading}
              className="px-5 py-2 rounded-xl bg-sky-600 hover:bg-sky-700 text-white font-bold shadow-xs disabled:opacity-50"
            >
              {loading ? 'جارٍ التسجيل...' : 'تسجيل العملية'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
};

// ==========================================
// Item Modal
// ==========================================
interface ItemModalProps {
  isOpen: boolean;
  item?: Item | null;
  onClose: () => void;
  onSuccess: () => void;
  onShowToast: (msg: string, type?: 'success' | 'error' | 'info') => void;
}

export const ItemModal: React.FC<ItemModalProps> = ({
  isOpen,
  item,
  onClose,
  onSuccess,
  onShowToast,
}) => {
  const [name, setName] = useState('');
  const [sku, setSku] = useState('');
  const [buyPrice, setBuyPrice] = useState<number>(0);
  const [sellPrice, setSellPrice] = useState<number>(0);
  const [quantity, setQuantity] = useState<number>(0);
  const [minQuantity, setMinQuantity] = useState<number>(5);
  const [category, setCategory] = useState('مواد غذائية');
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    if (item) {
      setName(item.name);
      setSku(item.sku || '');
      setBuyPrice(item.buy_price);
      setSellPrice(item.sell_price);
      setQuantity(item.quantity);
      setMinQuantity(item.min_quantity);
      setCategory(item.category || 'عام');
    } else {
      setName('');
      setSku('');
      setBuyPrice(0);
      setSellPrice(0);
      setQuantity(0);
      setMinQuantity(5);
      setCategory('مواد غذائية');
    }
  }, [item, isOpen]);

  if (!isOpen) return null;

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!name.trim()) {
      onShowToast('الرجاء إدخال اسم الصنف', 'error');
      return;
    }

    setLoading(true);
    try {
      if (item) {
        await api.updateItem(item.id, {
          name: name.trim(),
          sku: sku.trim(),
          buy_price: buyPrice,
          sell_price: sellPrice,
          quantity,
          min_quantity: minQuantity,
          category: category.trim(),
        });
        onShowToast('تم تحديث الصنف بنجاح', 'success');
      } else {
        await api.createItem({
          name: name.trim(),
          sku: sku.trim() || `SKU-${Date.now().toString().slice(-4)}`,
          buy_price: buyPrice,
          sell_price: sellPrice,
          quantity,
          min_quantity: minQuantity,
          category: category.trim(),
        });
        onShowToast('تم إضافة الصنف بنجاح', 'success');
      }
      onSuccess();
      onClose();
    } catch (err: any) {
      onShowToast(err.message || 'فشلت العملية', 'error');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="fixed inset-0 bg-slate-900/60 backdrop-blur-xs flex items-center justify-center p-4 z-50">
      <div className="bg-white rounded-3xl p-6 max-w-md w-full border border-slate-200 shadow-2xl space-y-4">
        <div className="flex items-center justify-between pb-3 border-b border-slate-100">
          <h3 className="font-black text-sm text-slate-900">
            {item ? 'تعديل صنف المخزون' : 'إضافة صنف جديد للمخزون'}
          </h3>
          <button onClick={onClose} className="p-1 rounded-lg text-slate-400 hover:text-slate-600">
            <X className="w-5 h-5" />
          </button>
        </div>

        <form onSubmit={handleSubmit} className="space-y-3 text-xs">
          <div>
            <label className="font-bold text-slate-700 block mb-1">اسم الصنف *</label>
            <input
              type="text"
              required
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="مثال: حليب ممتاز 1 لتر"
              className="w-full px-3 py-2 bg-slate-50 border border-slate-200 rounded-xl focus:bg-white focus:outline-hidden"
            />
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="font-bold text-slate-700 block mb-1">رمز SKU / الباركود</label>
              <input
                type="text"
                value={sku}
                onChange={(e) => setSku(e.target.value)}
                placeholder="SKU-101"
                className="w-full px-3 py-2 font-mono bg-slate-50 border border-slate-200 rounded-xl focus:bg-white focus:outline-hidden"
              />
            </div>

            <div>
              <label className="font-bold text-slate-700 block mb-1">الفئة / القسم</label>
              <input
                type="text"
                value={category}
                onChange={(e) => setCategory(e.target.value)}
                placeholder="مواد غذائية"
                className="w-full px-3 py-2 bg-slate-50 border border-slate-200 rounded-xl focus:bg-white focus:outline-hidden"
              />
            </div>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="font-bold text-slate-700 block mb-1">سعر الشراء (التكلفة)</label>
              <input
                type="number"
                min="0"
                value={buyPrice}
                onChange={(e) => setBuyPrice(Number(e.target.value) || 0)}
                className="w-full px-3 py-2 font-mono bg-slate-50 border border-slate-200 rounded-xl focus:bg-white focus:outline-hidden"
              />
            </div>

            <div>
              <label className="font-bold text-slate-700 block mb-1">سعر البيع للجمهور *</label>
              <input
                type="number"
                min="0"
                required
                value={sellPrice}
                onChange={(e) => setSellPrice(Number(e.target.value) || 0)}
                className="w-full px-3 py-2 font-mono font-bold bg-slate-50 border border-slate-200 rounded-xl focus:bg-white focus:outline-hidden"
              />
            </div>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="font-bold text-slate-700 block mb-1">الكمية المتوفرة بالمخزن</label>
              <input
                type="number"
                min="0"
                value={quantity}
                onChange={(e) => setQuantity(Number(e.target.value) || 0)}
                className="w-full px-3 py-2 font-mono bg-slate-50 border border-slate-200 rounded-xl focus:bg-white focus:outline-hidden"
              />
            </div>

            <div>
              <label className="font-bold text-slate-700 block mb-1">حد الطلب الأدنى للتنبيه</label>
              <input
                type="number"
                min="0"
                value={minQuantity}
                onChange={(e) => setMinQuantity(Number(e.target.value) || 0)}
                className="w-full px-3 py-2 font-mono bg-slate-50 border border-slate-200 rounded-xl focus:bg-white focus:outline-hidden"
              />
            </div>
          </div>

          <div className="flex justify-end gap-2 pt-3">
            <button
              type="button"
              onClick={onClose}
              className="px-4 py-2 rounded-xl text-slate-600 hover:bg-slate-100 font-bold"
            >
              إلغاء
            </button>
            <button
              type="submit"
              disabled={loading}
              className="px-5 py-2 rounded-xl bg-sky-600 hover:bg-sky-700 text-white font-bold shadow-xs disabled:opacity-50"
            >
              {loading ? 'جارٍ الحفظ...' : 'حفظ الصنف'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
};

// ==========================================
// User Modal
// ==========================================
interface UserModalProps {
  isOpen: boolean;
  user?: User | null;
  onClose: () => void;
  onSuccess: () => void;
  onShowToast: (msg: string, type?: 'success' | 'error' | 'info') => void;
}

export const UserModal: React.FC<UserModalProps> = ({
  isOpen,
  user,
  onClose,
  onSuccess,
  onShowToast,
}) => {
  const [name, setName] = useState('');
  const [role, setRole] = useState<UserRole>('agent');
  const [pin, setPin] = useState('');
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    if (user) {
      setName(user.name);
      setRole(user.role);
      setPin(user.pin || '');
    } else {
      setName('');
      setRole('agent');
      setPin('');
    }
  }, [user, isOpen]);

  if (!isOpen) return null;

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!name.trim()) {
      onShowToast('الرجاء إدخال اسم المستخدم', 'error');
      return;
    }

    setLoading(true);
    try {
      if (user) {
        await api.updateUser(user.id, {
          name: name.trim(),
          role,
          pin: pin.trim() || undefined,
        });
        onShowToast('تم تحديث المستخدم بنجاح', 'success');
      } else {
        await api.createUser({
          name: name.trim(),
          role,
          pin: pin.trim() || '1234',
        });
        onShowToast('تم إنشاء المستخدم بنجاح', 'success');
      }
      onSuccess();
      onClose();
    } catch (err: any) {
      onShowToast(err.message || 'فشلت العملية', 'error');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="fixed inset-0 bg-slate-900/60 backdrop-blur-xs flex items-center justify-center p-4 z-50">
      <div className="bg-white rounded-3xl p-6 max-w-md w-full border border-slate-200 shadow-2xl space-y-4">
        <div className="flex items-center justify-between pb-3 border-b border-slate-100">
          <h3 className="font-black text-sm text-slate-900">
            {user ? 'تعديل بيانات المستخدم' : 'إضافة مستخدم جديد'}
          </h3>
          <button onClick={onClose} className="p-1 rounded-lg text-slate-400 hover:text-slate-600">
            <X className="w-5 h-5" />
          </button>
        </div>

        <form onSubmit={handleSubmit} className="space-y-3 text-xs">
          <div>
            <label className="font-bold text-slate-700 block mb-1">اسم الموظف / المستخدم *</label>
            <input
              type="text"
              required
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="مثال: خالد محمد"
              className="w-full px-3 py-2 bg-slate-50 border border-slate-200 rounded-xl focus:bg-white focus:outline-hidden"
            />
          </div>

          <div>
            <label className="font-bold text-slate-700 block mb-1">الدور والصلاحيات</label>
            <select
              value={role}
              onChange={(e) => setRole(e.target.value as UserRole)}
              className="w-full px-3 py-2 bg-slate-50 border border-slate-200 rounded-xl font-bold focus:bg-white focus:outline-hidden"
            >
              <option value="agent">وكيل مبيعات (Agent)</option>
              <option value="accountant">محاسب (Accountant)</option>
              <option value="dataentry">مدخل بيانات (Data Entry)</option>
              <option value="viewer">مشاهد فقط (Viewer)</option>
              <option value="admin">مدير مشارك (Admin)</option>
            </select>
          </div>

          <div>
            <label className="font-bold text-slate-700 block mb-1">رمز الدخول السريع (PIN)</label>
            <input
              type="password"
              maxLength={6}
              value={pin}
              onChange={(e) => setPin(e.target.value)}
              placeholder="••••"
              className="w-full px-3 py-2 font-mono bg-slate-50 border border-slate-200 rounded-xl focus:bg-white focus:outline-hidden"
            />
          </div>

          <div className="flex justify-end gap-2 pt-3">
            <button
              type="button"
              onClick={onClose}
              className="px-4 py-2 rounded-xl text-slate-600 hover:bg-slate-100 font-bold"
            >
              إلغاء
            </button>
            <button
              type="submit"
              disabled={loading}
              className="px-5 py-2 rounded-xl bg-sky-600 hover:bg-sky-700 text-white font-bold shadow-xs disabled:opacity-50"
            >
              {loading ? 'جارٍ الحفظ...' : 'حفظ المستخدم'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
};

// ==========================================
// Voucher Modal
// ==========================================
interface VoucherModalProps {
  isOpen: boolean;
  accounts: Account[];
  onClose: () => void;
  onSuccess: () => void;
  onShowToast: (msg: string, type?: 'success' | 'error' | 'info') => void;
}

export const VoucherModal: React.FC<VoucherModalProps> = ({
  isOpen,
  accounts,
  onClose,
  onSuccess,
  onShowToast,
}) => {
  const [kind, setKind] = useState<VoucherKind>('receipt');
  const [accountId, setAccountId] = useState<string>('');
  const [amount, setAmount] = useState<number>(0);
  const [statement, setStatement] = useState('');
  const [loading, setLoading] = useState(false);

  if (!isOpen) return null;

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!amount || amount <= 0) {
      onShowToast('الرجاء إدخال مبلغ صحيح للسند', 'error');
      return;
    }

    setLoading(true);
    try {
      await api.createVoucher({
        kind,
        account_id: accountId ? Number(accountId) : undefined,
        amount,
        currency: 'YER',
        statement: statement.trim() || undefined,
        status: 'posted',
        date: new Date().toISOString(),
      });
      onShowToast('تم إصدار السند بنجاح', 'success');
      onSuccess();
      onClose();
    } catch (err: any) {
      onShowToast(err.message || 'فشل إنشاء السند', 'error');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="fixed inset-0 bg-slate-900/60 backdrop-blur-xs flex items-center justify-center p-4 z-50">
      <div className="bg-white rounded-3xl p-6 max-w-md w-full border border-slate-200 shadow-2xl space-y-4">
        <div className="flex items-center justify-between pb-3 border-b border-slate-100">
          <h3 className="font-black text-sm text-slate-900">إصدار سند رسمي جديد</h3>
          <button onClick={onClose} className="p-1 rounded-lg text-slate-400 hover:text-slate-600">
            <X className="w-5 h-5" />
          </button>
        </div>

        <form onSubmit={handleSubmit} className="space-y-3 text-xs">
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="font-bold text-slate-700 block mb-1">نوع السند</label>
              <select
                value={kind}
                onChange={(e) => setKind(e.target.value as VoucherKind)}
                className="w-full px-3 py-2 bg-slate-50 border border-slate-200 rounded-xl font-bold focus:bg-white focus:outline-hidden"
              >
                <option value="receipt">سند قبض (Receipt)</option>
                <option value="payment">سند صرف (Payment)</option>
                <option value="debit">قيد مدين</option>
                <option value="credit">قيد دائن</option>
              </select>
            </div>

            <div>
              <label className="font-bold text-slate-700 block mb-1">المبلغ (ر.ي) *</label>
              <input
                type="number"
                min="1"
                required
                value={amount || ''}
                onChange={(e) => setAmount(Number(e.target.value) || 0)}
                placeholder="0"
                className="w-full px-3 py-2 font-mono font-bold bg-slate-50 border border-slate-200 rounded-xl focus:bg-white focus:outline-hidden"
              />
            </div>
          </div>

          <div>
            <label className="font-bold text-slate-700 block mb-1">الحساب المستفيد / الدافع</label>
            <select
              value={accountId}
              onChange={(e) => setAccountId(e.target.value)}
              className="w-full px-3 py-2 bg-slate-50 border border-slate-200 rounded-xl font-medium focus:bg-white focus:outline-hidden"
            >
              <option value="">-- حساب نقدي عام --</option>
              {accounts.map((acc) => (
                <option key={acc.id} value={acc.id}>
                  {acc.name}
                </option>
              ))}
            </select>
          </div>

          <div>
            <label className="font-bold text-slate-700 block mb-1">البيان والشرح</label>
            <textarea
              rows={2}
              value={statement}
              onChange={(e) => setStatement(e.target.value)}
              placeholder="وذلك عن قيمة..."
              className="w-full px-3 py-2 bg-slate-50 border border-slate-200 rounded-xl focus:bg-white focus:outline-hidden"
            />
          </div>

          <div className="flex justify-end gap-2 pt-3">
            <button
              type="button"
              onClick={onClose}
              className="px-4 py-2 rounded-xl text-slate-600 hover:bg-slate-100 font-bold"
            >
              إلغاء
            </button>
            <button
              type="submit"
              disabled={loading}
              className="px-5 py-2 rounded-xl bg-sky-600 hover:bg-sky-700 text-white font-bold shadow-xs disabled:opacity-50"
            >
              {loading ? 'جارٍ الإصدار...' : 'إصدار السند'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
};
