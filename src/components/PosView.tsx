import React, { useState, useMemo } from 'react';
import {
  Search,
  ShoppingCart,
  Plus,
  Minus,
  Trash2,
  Check,
  CreditCard,
  Banknote,
  Package,
  Printer,
  MessageCircle,
  Copy,
  Barcode,
  LayoutGrid,
  List,
  Sparkles,
  User as UserIcon,
  Tag,
  Percent,
  Coins,
  ChevronDown,
  RotateCcw,
} from 'lucide-react';
import { Item, Account } from '../types';
import { api } from '../api';
import { usePermissions } from '../hooks/usePermissions';

interface PosViewProps {
  items: Item[];
  accounts: Account[];
  businessName?: string;
  onRefreshItems: () => void;
  onShowToast: (msg: string, type?: 'success' | 'error' | 'info') => void;
}

interface CartItem {
  item: Item;
  quantity: number;
  unitPrice: number;
}

type PaymentMethod = 'cash' | 'card' | 'credit' | 'split';
type ViewMode = 'grid' | 'compact';

export const PosView: React.FC<PosViewProps> = ({
  items,
  accounts,
  businessName = 'سجل المبيعات والديون',
  onRefreshItems,
  onShowToast,
}) => {
  const [search, setSearch] = useState('');
  const [selectedCategory, setSelectedCategory] = useState<string>('all');
  const [cart, setCart] = useState<CartItem[]>([]);
  const [discount, setDiscount] = useState<number>(0);
  const [discountType, setDiscountType] = useState<'fixed' | 'percent'>('fixed');
  const [discountPercent, setDiscountPercent] = useState<number>(0);
  const [selectedAccountId, setSelectedAccountId] = useState<string>('');
  const [paymentMethod, setPaymentMethod] = useState<PaymentMethod>('cash');
  const [receivedAmount, setReceivedAmount] = useState<string>('');
  const [orderNote, setOrderNote] = useState('');
  const [viewMode, setViewMode] = useState<ViewMode>('grid');
  const [isCheckingOut, setIsCheckingOut] = useState(false);
  const [lastReceipt, setLastReceipt] = useState<any | null>(null);
  const [copied, setCopied] = useState(false);

  const { canDiscount } = usePermissions();

  // Categories with count
  const categories = useMemo(() => {
    const map = new Map<string, number>();
    items.forEach((item) => {
      const cat = item.category?.trim() || 'عام';
      map.set(cat, (map.get(cat) || 0) + 1);
    });
    return [
      { id: 'all', name: 'الكل', count: items.length },
      ...Array.from(map.entries()).map(([name, count]) => ({ id: name, name, count })),
    ];
  }, [items]);

  const filteredItems = useMemo(() => {
    const q = search.trim().toLowerCase();
    return items.filter((item) => {
      const matchesSearch =
        !q ||
        item.name.toLowerCase().includes(q) ||
        (item.sku && item.sku.toLowerCase().includes(q));
      const matchesCategory =
        selectedCategory === 'all' ||
        (item.category?.trim() || 'عام') === selectedCategory;
      return matchesSearch && matchesCategory;
    });
  }, [items, search, selectedCategory]);

  const addToCart = (item: Item, delta = 1) => {
    setCart((prev) => {
      const existing = prev.find((c) => c.item.id === item.id);
      if (existing) {
        return prev.map((c) =>
          c.item.id === item.id ? { ...c, quantity: Math.max(1, c.quantity + delta) } : c
        );
      }
      return [...prev, { item, quantity: Math.max(1, delta), unitPrice: item.sell_price }];
    });
  };

  const handleBarcodeOrEnter = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter' && search.trim()) {
      const trimmed = search.trim().toLowerCase();
      const exactItem = items.find(
        (i) => i.sku?.toLowerCase() === trimmed || i.name.toLowerCase() === trimmed
      );
      if (exactItem) {
        addToCart(exactItem);
        onShowToast(`تمت إضافة "${exactItem.name}" إلى الفاتورة`, 'success');
        setSearch('');
        return;
      }
      if (filteredItems.length === 1) {
        addToCart(filteredItems[0]);
        onShowToast(`تمت إضافة "${filteredItems[0].name}" إلى الفاتورة`, 'success');
        setSearch('');
        return;
      }
    }
  };

  const updateQuantity = (itemId: number, delta: number) => {
    setCart((prev) =>
      prev
        .map((c) => {
          if (c.item.id === itemId) {
            const newQty = c.quantity + delta;
            return newQty > 0 ? { ...c, quantity: newQty } : null;
          }
          return c;
        })
        .filter(Boolean) as CartItem[]
    );
  };

  const removeFromCart = (itemId: number) => {
    setCart((prev) => prev.filter((c) => c.item.id !== itemId));
  };

  const clearCart = () => {
    setCart([]);
    setDiscount(0);
    setDiscountPercent(0);
    setSelectedAccountId('');
    setReceivedAmount('');
    setOrderNote('');
  };

  const subtotal = useMemo(
    () => cart.reduce((sum, c) => sum + c.quantity * c.unitPrice, 0),
    [cart]
  );

  const effectiveDiscount = useMemo(() => {
    if (discountType === 'percent') {
      return Math.round((subtotal * (discountPercent || 0)) / 100);
    }
    return discount || 0;
  }, [subtotal, discount, discountPercent, discountType]);

  const total = Math.max(0, subtotal - effectiveDiscount);

  const parsedReceived = parseFloat(receivedAmount) || 0;
  const changeDue = parsedReceived > total ? parsedReceived - total : 0;

  const handleApplyPercentDiscount = (pct: number) => {
    setDiscountType('percent');
    setDiscountPercent(pct);
  };

  const handleApplyFixedDiscount = (val: number) => {
    setDiscountType('fixed');
    setDiscount(val);
  };

  const handleCheckout = async () => {
    if (cart.length === 0) {
      onShowToast('السلة فارغة، يرجى اختيار أصناف أولاً', 'error');
      return;
    }

    if (paymentMethod === 'credit' && !selectedAccountId) {
      onShowToast('يجب اختيار حساب العميل للبيع الآجل', 'error');
      return;
    }

    setIsCheckingOut(true);
    try {
      const selectedAccount = accounts.find((a) => String(a.id) === selectedAccountId);
      const customerName = selectedAccount ? selectedAccount.name : 'عميل نقدي';

      const txItems = cart.map((c) => ({
        name: c.item.name,
        quantity: c.quantity,
        unit_price: c.unitPrice,
        total: c.quantity * c.unitPrice,
      }));

      const txType = paymentMethod === 'credit' ? 'debit' : 'inflow';
      const paymentLabel =
        paymentMethod === 'cash'
          ? 'نقداً 💵'
          : paymentMethod === 'card'
          ? 'شبكة / بنك 💳'
          : paymentMethod === 'credit'
          ? 'آجل 📑'
          : 'دفع جزئي ⚖️';

      const res = await api.createTransaction({
        account_id: selectedAccount ? selectedAccount.id : undefined,
        type: txType,
        amount: total,
        currency: 'YER',
        description: `فاتورة مبيعات (${paymentLabel}) - ${cart.length} أصناف${
          orderNote ? ` — ملاحظة: ${orderNote}` : ''
        }`,
        reference: `POS-${Date.now().toString().slice(-6)}`,
        items: txItems,
        date: new Date().toISOString(),
      });

      setLastReceipt({
        id: res.id,
        date: new Date().toLocaleString('ar-YE'),
        customerName,
        customerPhone: selectedAccount?.phone || selectedAccount?.whatsapp || '',
        paymentMode: paymentLabel,
        items: [...cart],
        subtotal,
        discount: effectiveDiscount,
        total,
        received: parsedReceived > 0 ? parsedReceived : total,
        change: changeDue,
        note: orderNote,
      });

      onShowToast(`✅ تم إصدار الفاتورة رقم #${res.id} بنجاح!`, 'success');
      clearCart();
      onRefreshItems();
    } catch (err: any) {
      onShowToast(err.message || 'فشلت عملية إصدار الفاتورة', 'error');
    } finally {
      setIsCheckingOut(false);
    }
  };

  const generateReceiptWhatsAppText = () => {
    if (!lastReceipt) return '';
    const itemsList = lastReceipt.items
      .map(
        (it: CartItem) =>
          `• ${it.item.name} × ${it.quantity} = ${(it.quantity * it.unitPrice).toLocaleString()} ر.ي`
      )
      .join('\n');

    return `🧾 *فاتورة مبيعات* — ${businessName}
━━━━━━━━━━━━━━━━━━
رقم الفاتورة: #${lastReceipt.id}
التاريخ: ${lastReceipt.date}
العميل: ${lastReceipt.customerName}
طريقة الدفع: ${lastReceipt.paymentMode}
━━━━━━━━━━━━━━━━━━
الأصناف:
${itemsList}
━━━━━━━━━━━━━━━━━━
المجموع: ${lastReceipt.subtotal.toLocaleString()} ر.ي
${lastReceipt.discount > 0 ? `الخصم: -${lastReceipt.discount.toLocaleString()} ر.ي\n` : ''}*الإجمالي الصافي:* ${lastReceipt.total.toLocaleString()} ر.ي
${lastReceipt.received ? `المستلم: ${lastReceipt.received.toLocaleString()} ر.ي\n` : ''}${lastReceipt.change > 0 ? `المتبقي للعميل: ${lastReceipt.change.toLocaleString()} ر.ي\n` : ''}━━━━━━━━━━━━━━━━━━
شكراً لتعاملكم معنا! نتطلع لخدمتكم مجدداً.`;
  };

  const handleShareReceiptWhatsApp = () => {
    const text = generateReceiptWhatsAppText();
    const phone = (lastReceipt?.customerPhone || '').replace(/[^0-9]/g, '');
    const url = phone
      ? `https://wa.me/${phone}?text=${encodeURIComponent(text)}`
      : `https://wa.me/?text=${encodeURIComponent(text)}`;
    window.open(url, '_blank');
    onShowToast('تم فتح واتساب لمشاركة الفاتورة', 'success');
  };

  const handleCopyReceiptText = () => {
    const text = generateReceiptWhatsAppText();
    navigator.clipboard.writeText(text);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
    onShowToast('تم نسخ نص الفاتورة إلى الحافظة', 'success');
  };

  // Helper map for quick cart item lookup
  const cartMap = useMemo(() => {
    const m = new Map<number, number>();
    cart.forEach((c) => m.set(c.item.id, c.quantity));
    return m;
  }, [cart]);

  return (
    <div className="space-y-4">
      {/* Receipt Modal */}
      {lastReceipt && (
        <div className="fixed inset-0 bg-slate-900/60 backdrop-blur-xs flex items-center justify-center p-4 z-50 animate-in fade-in duration-200">
          <div className="bg-white rounded-3xl p-6 max-w-sm w-full border border-slate-200 shadow-2xl space-y-4 text-right">
            <div className="text-center pb-3 border-b border-dashed border-slate-200">
              <div className="w-12 h-12 rounded-2xl bg-emerald-100 text-emerald-600 flex items-center justify-center mx-auto mb-2 text-2xl font-bold">
                ✓
              </div>
              <h3 className="font-extrabold text-base text-slate-900">{businessName}</h3>
              <p className="text-xs text-slate-400 font-mono">فاتورة مبيعات #{lastReceipt.id}</p>
            </div>

            <div className="text-xs space-y-1.5 text-slate-600">
              <div className="flex justify-between">
                <span>العميل:</span>
                <span className="font-bold text-slate-900">{lastReceipt.customerName}</span>
              </div>
              <div className="flex justify-between">
                <span>طريقة الدفع:</span>
                <span className="font-bold text-slate-900">{lastReceipt.paymentMode}</span>
              </div>
              <div className="flex justify-between">
                <span>التاريخ:</span>
                <span className="font-mono text-[11px]">{lastReceipt.date}</span>
              </div>
            </div>

            <div className="border-t border-b border-dashed border-slate-200 py-3 space-y-2 max-h-48 overflow-y-auto text-xs">
              {lastReceipt.items.map((it: CartItem, idx: number) => (
                <div key={idx} className="flex justify-between items-center">
                  <div>
                    <span className="font-semibold text-slate-800">{it.item.name}</span>
                    <span className="text-slate-400 text-[11px] mr-1">× {it.quantity}</span>
                  </div>
                  <span className="font-mono font-bold">
                    {(it.quantity * it.unitPrice).toLocaleString()} ر.ي
                  </span>
                </div>
              ))}
            </div>

            <div className="space-y-1 text-xs">
              {lastReceipt.discount > 0 && (
                <div className="flex justify-between text-slate-500">
                  <span>الخصم:</span>
                  <span className="font-mono text-rose-600">
                    -{lastReceipt.discount.toLocaleString()} ر.ي
                  </span>
                </div>
              )}
              <div className="flex justify-between text-base font-extrabold text-slate-900 pt-1">
                <span>الإجمالي:</span>
                <span className="text-emerald-600 font-mono font-bold">
                  {lastReceipt.total.toLocaleString()} ر.ي
                </span>
              </div>
              {lastReceipt.change > 0 && (
                <div className="flex justify-between text-sky-700 bg-sky-50 px-2 py-1 rounded-lg">
                  <span>المتبقي للعميل:</span>
                  <span className="font-mono font-bold">
                    {lastReceipt.change.toLocaleString()} ر.ي
                  </span>
                </div>
              )}
            </div>

            <div className="grid grid-cols-2 gap-2 pt-1">
              <button
                onClick={handleShareReceiptWhatsApp}
                className="py-2.5 px-3 rounded-xl bg-emerald-600 hover:bg-emerald-700 text-white text-xs font-bold flex items-center justify-center gap-1.5 transition-colors shadow-xs"
              >
                <MessageCircle className="w-4 h-4" />
                <span>واتساب</span>
              </button>
              <button
                onClick={handleCopyReceiptText}
                className="py-2.5 px-3 rounded-xl border border-slate-200 bg-slate-50 hover:bg-slate-100 text-slate-700 text-xs font-bold flex items-center justify-center gap-1.5 transition-colors"
              >
                {copied ? <Check className="w-4 h-4 text-emerald-600" /> : <Copy className="w-4 h-4" />}
                <span>{copied ? 'تم النسخ' : 'نسخ النص'}</span>
              </button>
            </div>

            <div className="flex gap-2">
              <button
                onClick={() => window.print()}
                className="flex-1 py-2.5 rounded-xl border border-slate-300 text-xs font-bold text-slate-700 hover:bg-slate-50 flex items-center justify-center gap-1.5"
              >
                <Printer className="w-4 h-4" />
                <span>طباعة حرارية</span>
              </button>
              <button
                onClick={() => setLastReceipt(null)}
                className="py-2.5 px-4 rounded-xl bg-slate-800 hover:bg-slate-900 text-white text-xs font-bold"
              >
                إغلاق
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Main Responsive Layout: Catalog Grid + Cart Panel */}
      <div className="grid grid-cols-1 lg:grid-cols-12 gap-5 items-start">
        {/* Left/Main Column: Items Catalog (7 or 8 columns on large screens) */}
        <div className="lg:col-span-7 xl:col-span-8 space-y-4">
          {/* Top Search & Controls Bar */}
          <div className="bg-white rounded-2xl p-3.5 border border-slate-200 shadow-xs flex flex-col sm:flex-row items-stretch sm:items-center justify-between gap-3">
            {/* Search Input with Barcode support */}
            <div className="relative flex-1">
              <Search className="w-4 h-4 absolute right-3.5 top-3.5 text-slate-400" />
              <input
                type="text"
                value={search}
                onChange={(e) => setSearch(e.target.value)}
                onKeyDown={handleBarcodeOrEnter}
                placeholder="ابحث بالاسم، الكود، أو امسح الباركود..."
                className="w-full pr-10 pl-10 py-2.5 bg-slate-50 border border-slate-200/80 rounded-xl text-xs sm:text-sm font-medium focus:bg-white focus:border-sky-500 focus:outline-hidden transition-all"
              />
              <div className="absolute left-3 top-3 text-slate-400" title="ماسح الباركود نشط">
                <Barcode className="w-4 h-4" />
              </div>
            </div>

            {/* View Mode Toggle & Active Item Count */}
            <div className="flex items-center justify-between sm:justify-end gap-2">
              <span className="text-xs font-bold text-slate-500 px-2 py-1 bg-slate-100 rounded-lg">
                {filteredItems.length} صنف
              </span>

              <div className="flex items-center bg-slate-100 p-1 rounded-xl border border-slate-200/60">
                <button
                  type="button"
                  onClick={() => setViewMode('grid')}
                  className={`p-1.5 rounded-lg text-xs transition-colors ${
                    viewMode === 'grid'
                      ? 'bg-white text-sky-600 shadow-xs font-bold'
                      : 'text-slate-500 hover:text-slate-900'
                  }`}
                  title="عرض كروت كبيرة"
                >
                  <LayoutGrid className="w-4 h-4" />
                </button>
                <button
                  type="button"
                  onClick={() => setViewMode('compact')}
                  className={`p-1.5 rounded-lg text-xs transition-colors ${
                    viewMode === 'compact'
                      ? 'bg-white text-sky-600 shadow-xs font-bold'
                      : 'text-slate-500 hover:text-slate-900'
                  }`}
                  title="عرض سريع مدمج"
                >
                  <List className="w-4 h-4" />
                </button>
              </div>
            </div>
          </div>

          {/* Category Filter Pills */}
          <div className="flex items-center gap-2 overflow-x-auto pb-1 scrollbar-none">
            {categories.map((cat) => {
              const active = selectedCategory === cat.id;
              return (
                <button
                  key={cat.id}
                  onClick={() => setSelectedCategory(cat.id)}
                  className={`px-3.5 py-2 rounded-xl text-xs font-bold whitespace-nowrap transition-all flex items-center gap-1.5 shrink-0 ${
                    active
                      ? 'bg-sky-600 text-white shadow-xs scale-102'
                      : 'bg-white text-slate-600 hover:bg-slate-100 border border-slate-200/80'
                  }`}
                >
                  <span>{cat.name}</span>
                  <span
                    className={`text-[10px] px-1.5 py-0.2 rounded-full ${
                      active ? 'bg-sky-700 text-white' : 'bg-slate-100 text-slate-500'
                    }`}
                  >
                    {cat.count}
                  </span>
                </button>
              );
            })}
          </div>

          {/* Items Container */}
          {filteredItems.length === 0 ? (
            <div className="bg-white rounded-2xl border border-slate-200 p-12 text-center text-slate-400 space-y-2">
              <Package className="w-12 h-12 mx-auto text-slate-300 stroke-1" />
              <p className="font-bold text-sm text-slate-600">لم يتم العثور على أي أصناف</p>
              <p className="text-xs text-slate-400">جرّب تغيير عبارة البحث أو الفئة المحددة</p>
            </div>
          ) : viewMode === 'grid' ? (
            /* Visual Grid Mode */
            <div className="grid grid-cols-2 sm:grid-cols-3 xl:grid-cols-4 gap-3">
              {filteredItems.map((item) => {
                const qtyInCart = cartMap.get(item.id) || 0;
                const isOutOfStock = item.quantity <= 0;
                const isLowStock = item.quantity > 0 && item.quantity <= (item.min_quantity || 3);

                return (
                  <div
                    key={item.id}
                    onClick={() => addToCart(item)}
                    className={`group relative bg-white rounded-2xl p-3.5 border transition-all cursor-pointer flex flex-col justify-between hover:shadow-md hover:-translate-y-0.5 active:scale-98 select-none ${
                      qtyInCart > 0
                        ? 'border-sky-500 ring-2 ring-sky-500/20 bg-sky-50/20'
                        : 'border-slate-200/80 hover:border-sky-300'
                    }`}
                  >
                    {/* Top Row: Category tag & Stock Badge */}
                    <div className="flex items-center justify-between gap-1 mb-2">
                      <span className="text-[10px] font-bold text-slate-400 truncate max-w-[80px]">
                        {item.category || 'عام'}
                      </span>
                      <span
                        className={`text-[10px] font-extrabold px-1.5 py-0.5 rounded-md ${
                          isOutOfStock
                            ? 'bg-rose-50 text-rose-600'
                            : isLowStock
                            ? 'bg-amber-50 text-amber-600'
                            : 'bg-emerald-50 text-emerald-600'
                        }`}
                      >
                        {isOutOfStock ? 'نفد' : `${item.quantity} متوفر`}
                      </span>
                    </div>

                    {/* Item Name */}
                    <div className="my-1 flex-1">
                      <h4 className="font-bold text-slate-800 text-xs sm:text-sm line-clamp-2 group-hover:text-sky-600 transition-colors">
                        {item.name}
                      </h4>
                      {item.sku && (
                        <p className="text-[10px] text-slate-400 font-mono mt-0.5">{item.sku}</p>
                      )}
                    </div>

                    {/* Bottom Row: Price & Cart Counter */}
                    <div className="mt-3 pt-2 border-t border-slate-100 flex items-center justify-between">
                      <div>
                        <span className="text-sm sm:text-base font-extrabold font-mono text-emerald-600">
                          {item.sell_price.toLocaleString()}
                        </span>
                        <span className="text-[10px] text-slate-400 mr-1 font-bold">ر.ي</span>
                      </div>

                      {qtyInCart > 0 ? (
                        <div className="flex items-center gap-1 bg-sky-600 text-white px-2 py-0.5 rounded-lg text-xs font-bold shadow-xs">
                          <span>{qtyInCart}</span>
                        </div>
                      ) : (
                        <button
                          type="button"
                          className="w-7 h-7 rounded-xl bg-slate-100 group-hover:bg-sky-600 group-hover:text-white text-slate-600 flex items-center justify-center transition-all"
                        >
                          <Plus className="w-3.5 h-3.5" />
                        </button>
                      )}
                    </div>
                  </div>
                );
              })}
            </div>
          ) : (
            /* High-Speed Compact List Mode */
            <div className="bg-white rounded-2xl border border-slate-200 divide-y divide-slate-100 overflow-hidden shadow-xs">
              {filteredItems.map((item) => {
                const qtyInCart = cartMap.get(item.id) || 0;
                return (
                  <div
                    key={item.id}
                    onClick={() => addToCart(item)}
                    className="p-3 flex items-center justify-between hover:bg-slate-50 transition-colors cursor-pointer group"
                  >
                    <div className="flex items-center gap-3">
                      <div className="w-8 h-8 rounded-xl bg-slate-100 flex items-center justify-center text-slate-600 font-bold group-hover:bg-sky-600 group-hover:text-white transition-colors">
                        <Package className="w-4 h-4" />
                      </div>
                      <div>
                        <div className="font-bold text-slate-800 text-xs sm:text-sm">{item.name}</div>
                        <div className="text-[10px] text-slate-400 font-mono flex items-center gap-2">
                          <span>{item.category || 'عام'}</span>
                          {item.sku && <span>• {item.sku}</span>}
                          <span>• المخزون: {item.quantity}</span>
                        </div>
                      </div>
                    </div>

                    <div className="flex items-center gap-3">
                      <span className="font-bold font-mono text-sm text-emerald-600">
                        {item.sell_price.toLocaleString()} ر.ي
                      </span>
                      {qtyInCart > 0 ? (
                        <span className="px-2.5 py-1 rounded-lg bg-sky-600 text-white font-bold text-xs">
                          {qtyInCart} في السلة
                        </span>
                      ) : (
                        <button
                          type="button"
                          className="w-7 h-7 rounded-lg bg-slate-100 text-slate-600 group-hover:bg-sky-600 group-hover:text-white flex items-center justify-center transition-colors"
                        >
                          <Plus className="w-3.5 h-3.5" />
                        </button>
                      )}
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </div>

        {/* Right/Cart Column: Smart Checkout Sidebar (5 or 4 columns) */}
        <div className="lg:col-span-5 xl:col-span-4 bg-white rounded-3xl p-4 sm:p-5 border border-slate-200/90 shadow-sm space-y-4 sticky top-4">
          {/* Cart Header */}
          <div className="flex items-center justify-between pb-3 border-b border-slate-100">
            <div className="flex items-center gap-2">
              <div className="w-8 h-8 rounded-xl bg-sky-50 text-sky-600 flex items-center justify-center font-bold">
                <ShoppingCart className="w-4 h-4" />
              </div>
              <h3 className="font-extrabold text-slate-900 text-sm sm:text-base">سلة البيع</h3>
              <span className="text-xs px-2 py-0.5 rounded-full bg-slate-100 text-slate-600 font-bold">
                {cart.length} أصناف
              </span>
            </div>

            {cart.length > 0 && (
              <button
                onClick={clearCart}
                className="text-xs text-rose-500 hover:text-rose-700 flex items-center gap-1 font-bold p-1 rounded-lg hover:bg-rose-50 transition-colors"
                title="إفراغ السلة"
              >
                <Trash2 className="w-3.5 h-3.5" />
                <span>إفراغ</span>
              </button>
            )}
          </div>

          {/* Customer Picker */}
          <div className="space-y-1.5">
            <label className="text-xs font-bold text-slate-600 flex items-center justify-between">
              <span className="flex items-center gap-1.5">
                <UserIcon className="w-3.5 h-3.5 text-slate-400" />
                <span>العميل / الحساب:</span>
              </span>
              {selectedAccountId && (
                <button
                  type="button"
                  onClick={() => setSelectedAccountId('')}
                  className="text-[11px] text-sky-600 hover:underline"
                >
                  تعيين كعميل نقدي
                </button>
              )}
            </label>
            <select
              value={selectedAccountId}
              onChange={(e) => setSelectedAccountId(e.target.value)}
              className="w-full px-3 py-2 bg-slate-50 border border-slate-200 rounded-xl text-xs font-medium focus:bg-white focus:border-sky-500 focus:outline-hidden"
            >
              <option value="">عميل نقدي (بدون حساب)</option>
              {accounts.map((acc) => (
                <option key={acc.id} value={acc.id}>
                  {acc.name} ({acc.kind === 'customer' ? 'عميل' : 'مورد'} • {acc.currency})
                </option>
              ))}
            </select>
          </div>

          {/* Cart Items List */}
          <div className="space-y-2 max-h-60 overflow-y-auto pr-1">
            {cart.length === 0 ? (
              <div className="py-8 text-center text-slate-400 space-y-1 border border-dashed border-slate-200 rounded-2xl">
                <ShoppingCart className="w-8 h-8 mx-auto text-slate-300 stroke-1" />
                <p className="text-xs font-bold text-slate-500">السلة فارغة</p>
                <p className="text-[11px] text-slate-400">انقر على أي صنف لإضافته فوراً</p>
              </div>
            ) : (
              cart.map((c) => (
                <div
                  key={c.item.id}
                  className="flex items-center justify-between p-2.5 rounded-xl bg-slate-50/80 border border-slate-100 gap-2"
                >
                  <div className="min-w-0 flex-1">
                    <div className="font-bold text-xs text-slate-800 truncate">{c.item.name}</div>
                    <div className="text-[11px] text-slate-400 font-mono mt-0.5">
                      {c.unitPrice.toLocaleString()} ر.ي × {c.quantity} ={' '}
                      <span className="font-bold text-slate-700">
                        {(c.quantity * c.unitPrice).toLocaleString()} ر.ي
                      </span>
                    </div>
                  </div>

                  <div className="flex items-center gap-1 shrink-0">
                    <button
                      onClick={() => updateQuantity(c.item.id, -1)}
                      className="w-6 h-6 rounded-lg bg-white border border-slate-200 hover:bg-slate-100 flex items-center justify-center text-slate-600 transition-colors"
                    >
                      <Minus className="w-3 h-3" />
                    </button>
                    <span className="w-6 text-center font-bold text-xs font-mono text-slate-800">
                      {c.quantity}
                    </span>
                    <button
                      onClick={() => updateQuantity(c.item.id, 1)}
                      className="w-6 h-6 rounded-lg bg-white border border-slate-200 hover:bg-slate-100 flex items-center justify-center text-slate-600 transition-colors"
                    >
                      <Plus className="w-3 h-3" />
                    </button>
                    <button
                      onClick={() => removeFromCart(c.item.id)}
                      className="w-6 h-6 rounded-lg hover:bg-rose-50 text-slate-400 hover:text-rose-600 flex items-center justify-center transition-colors mr-1"
                    >
                      <Trash2 className="w-3.5 h-3.5" />
                    </button>
                  </div>
                </div>
              ))
            )}
          </div>

          {/* Quick Discount Presets */}
          {canDiscount && (
            <div className="space-y-1.5 pt-2 border-t border-slate-100">
              <div className="flex items-center justify-between text-xs font-bold text-slate-600">
                <span className="flex items-center gap-1.5">
                  <Percent className="w-3.5 h-3.5 text-slate-400" />
                  <span>الخصم:</span>
                </span>
                <span className="font-mono text-rose-600">
                  {effectiveDiscount > 0 ? `-${effectiveDiscount.toLocaleString()} ر.ي` : 'لا يوجد'}
                </span>
              </div>

              <div className="flex items-center gap-1.5">
                {[0, 5, 10, 15, 20].map((pct) => (
                  <button
                    key={pct}
                    type="button"
                    onClick={() => handleApplyPercentDiscount(pct)}
                    className={`flex-1 py-1 rounded-lg text-xs font-bold transition-colors ${
                      discountType === 'percent' && discountPercent === pct
                        ? 'bg-rose-600 text-white shadow-xs'
                        : 'bg-slate-100 text-slate-600 hover:bg-slate-200'
                    }`}
                  >
                    {pct === 0 ? 'بدون' : `${pct}%`}
                  </button>
                ))}
              </div>
            </div>
          )}

          {/* Payment Method Selector */}
          <div className="space-y-1.5 pt-2 border-t border-slate-100">
            <label className="text-xs font-bold text-slate-600 flex items-center gap-1.5">
              <Coins className="w-3.5 h-3.5 text-slate-400" />
              <span>طريقة الدفع:</span>
            </label>
            <div className="grid grid-cols-4 gap-1.5">
              <button
                type="button"
                onClick={() => setPaymentMethod('cash')}
                className={`py-2 px-1 rounded-xl text-xs font-bold flex flex-col items-center gap-1 transition-all ${
                  paymentMethod === 'cash'
                    ? 'bg-emerald-600 text-white shadow-xs scale-102'
                    : 'bg-slate-50 text-slate-600 hover:bg-slate-100 border border-slate-200/80'
                }`}
              >
                <Banknote className="w-4 h-4" />
                <span>نقداً</span>
              </button>

              <button
                type="button"
                onClick={() => setPaymentMethod('card')}
                className={`py-2 px-1 rounded-xl text-xs font-bold flex flex-col items-center gap-1 transition-all ${
                  paymentMethod === 'card'
                    ? 'bg-sky-600 text-white shadow-xs scale-102'
                    : 'bg-slate-50 text-slate-600 hover:bg-slate-100 border border-slate-200/80'
                }`}
              >
                <CreditCard className="w-4 h-4" />
                <span>شبكة/بنك</span>
              </button>

              <button
                type="button"
                onClick={() => setPaymentMethod('credit')}
                className={`py-2 px-1 rounded-xl text-xs font-bold flex flex-col items-center gap-1 transition-all ${
                  paymentMethod === 'credit'
                    ? 'bg-amber-600 text-white shadow-xs scale-102'
                    : 'bg-slate-50 text-slate-600 hover:bg-slate-100 border border-slate-200/80'
                }`}
              >
                <Tag className="w-4 h-4" />
                <span>آجل</span>
              </button>

              <button
                type="button"
                onClick={() => setPaymentMethod('split')}
                className={`py-2 px-1 rounded-xl text-xs font-bold flex flex-col items-center gap-1 transition-all ${
                  paymentMethod === 'split'
                    ? 'bg-purple-600 text-white shadow-xs scale-102'
                    : 'bg-slate-50 text-slate-600 hover:bg-slate-100 border border-slate-200/80'
                }`}
              >
                <Sparkles className="w-4 h-4" />
                <span>جزئي</span>
              </button>
            </div>
          </div>

          {/* Quick Cash Numpad / Tendered Amount */}
          {paymentMethod === 'cash' && cart.length > 0 && (
            <div className="space-y-1.5 bg-slate-50 p-2.5 rounded-2xl border border-slate-200/80 text-xs">
              <div className="flex items-center justify-between text-slate-600 font-bold">
                <span>المبلغ المستلم من العميل:</span>
                <input
                  type="number"
                  value={receivedAmount}
                  onChange={(e) => setReceivedAmount(e.target.value)}
                  placeholder={`${total}`}
                  className="w-28 text-left font-mono font-bold px-2 py-1 bg-white border border-slate-300 rounded-lg text-xs"
                />
              </div>

              {/* Quick Cash Presets */}
              <div className="flex items-center gap-1 pt-1">
                {[total, 1000, 2000, 5000, 10000, 20000]
                  .filter((v, i, a) => v >= total && a.indexOf(v) === i)
                  .slice(0, 4)
                  .map((amount) => (
                    <button
                      key={amount}
                      type="button"
                      onClick={() => setReceivedAmount(String(amount))}
                      className="flex-1 py-1 rounded-lg bg-white border border-slate-200 text-slate-700 font-mono font-bold text-[11px] hover:bg-slate-100"
                    >
                      {amount.toLocaleString()}
                    </button>
                  ))}
              </div>

              {changeDue > 0 && (
                <div className="flex items-center justify-between pt-1 text-emerald-700 font-bold">
                  <span>المتبقي للعميل (الباقي):</span>
                  <span className="font-mono text-sm">{changeDue.toLocaleString()} ر.ي</span>
                </div>
              )}
            </div>
          )}

          {/* Financial Totals Summary */}
          <div className="space-y-1.5 pt-2 border-t border-slate-200 text-xs">
            <div className="flex justify-between text-slate-500">
              <span>المجموع الفرعي:</span>
              <span className="font-mono font-bold">{subtotal.toLocaleString()} ر.ي</span>
            </div>

            {effectiveDiscount > 0 && (
              <div className="flex justify-between text-rose-600">
                <span>الخصم:</span>
                <span className="font-mono font-bold">-{effectiveDiscount.toLocaleString()} ر.ي</span>
              </div>
            )}

            <div className="flex justify-between text-base font-extrabold text-slate-900 pt-1 border-t border-dashed border-slate-200">
              <span>الإجمالي الصافي:</span>
              <span className="text-emerald-600 font-mono text-lg font-black">
                {total.toLocaleString()} ر.ي
              </span>
            </div>
          </div>

          {/* Action Checkout Button */}
          <button
            id="btn-complete-pos-checkout"
            onClick={handleCheckout}
            disabled={isCheckingOut || cart.length === 0}
            className={`w-full py-3.5 rounded-2xl text-white font-extrabold text-sm sm:text-base flex items-center justify-center gap-2 shadow-md transition-all active:scale-98 cursor-pointer ${
              cart.length === 0
                ? 'bg-slate-300 cursor-not-allowed shadow-none'
                : paymentMethod === 'credit'
                ? 'bg-amber-600 hover:bg-amber-700 shadow-amber-600/20'
                : 'bg-emerald-600 hover:bg-emerald-700 shadow-emerald-600/20'
            }`}
          >
            {isCheckingOut ? (
              <span>جارٍ إصدار الفاتورة...</span>
            ) : (
              <>
                <Check className="w-5 h-5 stroke-2" />
                <span>إتمام البيع ({total.toLocaleString()} ر.ي)</span>
              </>
            )}
          </button>
        </div>
      </div>
    </div>
  );
};
