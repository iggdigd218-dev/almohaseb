import React, { useState, useMemo } from 'react';
import {
  Package,
  Plus,
  Search,
  Edit2,
  Trash2,
  AlertTriangle,
  TrendingUp,
  DollarSign,
  Layers,
  ArrowUpDown,
  CheckCircle2,
  XCircle,
  BarChart3,
  SlidersHorizontal,
} from 'lucide-react';
import { Item } from '../types';
import { api } from '../api';
import { ConfirmModal } from './ConfirmModal';
import { usePermissions } from '../hooks/usePermissions';

interface InventoryViewProps {
  items: Item[];
  onRefresh: () => void;
  onOpenItemModal: (item?: Item) => void;
  onShowToast: (msg: string, type?: 'success' | 'error' | 'info') => void;
}

type StockFilter = 'all' | 'low' | 'out';
type SortField = 'name' | 'quantity' | 'sell_price' | 'profit';
type SortOrder = 'asc' | 'desc';

export const InventoryView: React.FC<InventoryViewProps> = ({
  items,
  onRefresh,
  onOpenItemModal,
  onShowToast,
}) => {
  const [search, setSearch] = useState('');
  const [categoryFilter, setCategoryFilter] = useState('all');
  const [stockFilter, setStockFilter] = useState<StockFilter>('all');
  const [sortField, setSortField] = useState<SortField>('name');
  const [sortOrder, setSortOrder] = useState<SortOrder>('asc');
  const [deleteItemTarget, setDeleteItemTarget] = useState<Item | null>(null);
  const [isDeleting, setIsDeleting] = useState(false);
  const [quickAdjustItemId, setQuickAdjustItemId] = useState<number | null>(null);

  const { canManageItems } = usePermissions();

  // Inventory KPI Metrics
  const metrics = useMemo(() => {
    let totalCost = 0;
    let totalRetail = 0;
    let lowStockCount = 0;
    let outOfStockCount = 0;

    items.forEach((item) => {
      const q = Math.max(0, item.quantity);
      totalCost += q * (item.buy_price || 0);
      totalRetail += q * (item.sell_price || 0);
      if (item.quantity <= 0) {
        outOfStockCount++;
      } else if (item.quantity <= (item.min_quantity || 3)) {
        lowStockCount++;
      }
    });

    const expectedProfit = Math.max(0, totalRetail - totalCost);

    return {
      totalItems: items.length,
      totalCost,
      totalRetail,
      expectedProfit,
      lowStockCount,
      outOfStockCount,
    };
  }, [items]);

  // Categories list
  const categories = useMemo(() => {
    const set = new Set<string>();
    items.forEach((i) => {
      if (i.category?.trim()) set.add(i.category.trim());
    });
    return ['all', ...Array.from(set)];
  }, [items]);

  // Filtered & Sorted items
  const filteredItems = useMemo(() => {
    const q = search.trim().toLowerCase();

    return items
      .filter((item) => {
        const matchesSearch =
          !q ||
          item.name.toLowerCase().includes(q) ||
          (item.sku && item.sku.toLowerCase().includes(q)) ||
          (item.category && item.category.toLowerCase().includes(q));

        const matchesCat =
          categoryFilter === 'all' || (item.category?.trim() || 'عام') === categoryFilter;

        const matchesStock =
          stockFilter === 'all'
            ? true
            : stockFilter === 'out'
            ? item.quantity <= 0
            : item.quantity > 0 && item.quantity <= (item.min_quantity || 3);

        return matchesSearch && matchesCat && matchesStock;
      })
      .sort((a, b) => {
        let valA: any = a.name;
        let valB: any = b.name;

        if (sortField === 'quantity') {
          valA = a.quantity;
          valB = b.quantity;
        } else if (sortField === 'sell_price') {
          valA = a.sell_price;
          valB = b.sell_price;
        } else if (sortField === 'profit') {
          valA = (a.sell_price || 0) - (a.buy_price || 0);
          valB = (b.sell_price || 0) - (b.buy_price || 0);
        }

        if (valA < valB) return sortOrder === 'asc' ? -1 : 1;
        if (valA > valB) return sortOrder === 'asc' ? 1 : -1;
        return 0;
      });
  }, [items, search, categoryFilter, stockFilter, sortField, sortOrder]);

  const toggleSort = (field: SortField) => {
    if (sortField === field) {
      setSortOrder((prev) => (prev === 'asc' ? 'desc' : 'asc'));
    } else {
      setSortField(field);
      setSortOrder('desc');
    }
  };

  const handleQuickStockAdjust = async (item: Item, delta: number) => {
    if (!canManageItems) return;
    const newQty = Math.max(0, item.quantity + delta);
    setQuickAdjustItemId(item.id);
    try {
      await api.updateItem(item.id, { quantity: newQty });
      onShowToast(
        `تم تعديل رصيد "${item.name}" إلى ${newQty} ${item.unit || 'حبة'}`,
        'success'
      );
      onRefresh();
    } catch (err: any) {
      onShowToast(err.message || 'فشل تحديث المخزون', 'error');
    } finally {
      setQuickAdjustItemId(null);
    }
  };

  const handleConfirmDelete = async () => {
    if (!deleteItemTarget || !canManageItems) return;
    setIsDeleting(true);
    try {
      await api.deleteItem(deleteItemTarget.id);
      onShowToast(`تم حذف الصنف "${deleteItemTarget.name}" بنجاح`, 'success');
      setDeleteItemTarget(null);
      onRefresh();
    } catch (err: any) {
      onShowToast(err.message || 'فشل حذف الصنف', 'error');
    } finally {
      setIsDeleting(false);
    }
  };

  return (
    <div className="space-y-4">
      {/* Delete Confirmation Modal */}
      {deleteItemTarget && (
        <ConfirmModal
          isOpen={true}
          title="حذف صنف من المخزون"
          message={`هل أنت متأكد من حذف الصنف "${deleteItemTarget.name}"؟`}
          confirmLabel="نعم، حذف الصنف"
          variant="danger"
          isLoading={isDeleting}
          onConfirm={handleConfirmDelete}
          onCancel={() => setDeleteItemTarget(null)}
        />
      )}

      {/* KPI Stats Cards */}
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-3">
        {/* Total Items */}
        <div className="bg-white rounded-2xl p-4 border border-slate-200/90 shadow-xs flex items-center gap-3">
          <div className="w-10 h-10 rounded-xl bg-sky-50 text-sky-600 flex items-center justify-center shrink-0">
            <Package className="w-5 h-5" />
          </div>
          <div className="min-w-0">
            <p className="text-[11px] font-bold text-slate-500">إجمالي الأصناف</p>
            <p className="text-lg font-black text-slate-900 font-mono">
              {metrics.totalItems} <span className="text-xs font-normal text-slate-400">صنف</span>
            </p>
          </div>
        </div>

        {/* Total Cost Value */}
        <div className="bg-white rounded-2xl p-4 border border-slate-200/90 shadow-xs flex items-center gap-3">
          <div className="w-10 h-10 rounded-xl bg-indigo-50 text-indigo-600 flex items-center justify-center shrink-0">
            <DollarSign className="w-5 h-5" />
          </div>
          <div className="min-w-0">
            <p className="text-[11px] font-bold text-slate-500">قيمة التكلفة للمخزون</p>
            <p className="text-lg font-black text-slate-900 font-mono">
              {metrics.totalCost.toLocaleString()}{' '}
              <span className="text-[11px] font-normal text-slate-400">ر.ي</span>
            </p>
          </div>
        </div>

        {/* Expected Retail Value & Margin */}
        <div className="bg-white rounded-2xl p-4 border border-slate-200/90 shadow-xs flex items-center gap-3">
          <div className="w-10 h-10 rounded-xl bg-emerald-50 text-emerald-600 flex items-center justify-center shrink-0">
            <TrendingUp className="w-5 h-5" />
          </div>
          <div className="min-w-0">
            <p className="text-[11px] font-bold text-slate-500">القيمة البيعية المتوقعة</p>
            <p className="text-lg font-black text-emerald-600 font-mono">
              {metrics.totalRetail.toLocaleString()}{' '}
              <span className="text-[11px] font-normal text-slate-400">ر.ي</span>
            </p>
          </div>
        </div>

        {/* Low & Out of stock Alerts */}
        <div
          onClick={() => setStockFilter(stockFilter === 'low' ? 'all' : 'low')}
          className={`bg-white rounded-2xl p-4 border shadow-xs flex items-center gap-3 cursor-pointer transition-all ${
            stockFilter === 'low' ? 'border-amber-500 ring-2 ring-amber-500/20' : 'border-slate-200/90'
          }`}
        >
          <div className="w-10 h-10 rounded-xl bg-amber-50 text-amber-600 flex items-center justify-center shrink-0">
            <AlertTriangle className="w-5 h-5" />
          </div>
          <div className="min-w-0">
            <p className="text-[11px] font-bold text-slate-500">نواقص تحتاج توريد</p>
            <p className="text-lg font-black text-amber-600 font-mono">
              {metrics.lowStockCount + metrics.outOfStockCount}{' '}
              <span className="text-xs font-normal text-slate-400">
                ({metrics.outOfStockCount} نافد)
              </span>
            </p>
          </div>
        </div>
      </div>

      {/* Control Bar: Categories, Search, Filters, Add Button */}
      <div className="bg-white rounded-2xl p-4 border border-slate-200 shadow-xs space-y-3">
        <div className="flex flex-col sm:flex-row items-stretch sm:items-center justify-between gap-3">
          {/* Search Box */}
          <div className="relative flex-1">
            <Search className="w-4 h-4 absolute right-3.5 top-3.5 text-slate-400" />
            <input
              type="text"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="ابحث بالاسم، رمز SKU، أو الفئة..."
              className="w-full pr-10 pl-4 py-2.5 bg-slate-50 border border-slate-200 rounded-xl text-xs sm:text-sm font-medium focus:bg-white focus:border-sky-500 focus:outline-hidden transition-colors"
            />
          </div>

          {/* Stock Filter Pills */}
          <div className="flex items-center gap-1.5 bg-slate-100 p-1 rounded-xl self-start sm:self-auto">
            <button
              onClick={() => setStockFilter('all')}
              className={`px-3 py-1.5 rounded-lg text-xs font-bold transition-all ${
                stockFilter === 'all'
                  ? 'bg-white text-slate-900 shadow-xs'
                  : 'text-slate-600 hover:text-slate-900'
              }`}
            >
              الكل ({items.length})
            </button>
            <button
              onClick={() => setStockFilter('low')}
              className={`px-3 py-1.5 rounded-lg text-xs font-bold transition-all flex items-center gap-1 ${
                stockFilter === 'low'
                  ? 'bg-amber-500 text-white shadow-xs'
                  : 'text-amber-700 hover:text-amber-800'
              }`}
            >
              <AlertTriangle className="w-3.5 h-3.5" />
              <span>منخفض ({metrics.lowStockCount})</span>
            </button>
            <button
              onClick={() => setStockFilter('out')}
              className={`px-3 py-1.5 rounded-lg text-xs font-bold transition-all flex items-center gap-1 ${
                stockFilter === 'out'
                  ? 'bg-rose-600 text-white shadow-xs'
                  : 'text-rose-600 hover:text-rose-700'
              }`}
            >
              <XCircle className="w-3.5 h-3.5" />
              <span>نافد ({metrics.outOfStockCount})</span>
            </button>
          </div>

          {/* Add Item Button */}
          {canManageItems && (
            <button
              id="btn-add-item-view"
              onClick={() => onOpenItemModal()}
              className="flex items-center justify-center gap-1.5 px-4 py-2.5 text-xs sm:text-sm font-extrabold bg-sky-600 hover:bg-sky-700 text-white rounded-xl shadow-xs transition-colors shrink-0"
            >
              <Plus className="w-4 h-4 stroke-2" />
              <span>صنف جديد</span>
            </button>
          )}
        </div>

        {/* Category Pills Bar */}
        <div className="flex items-center gap-2 overflow-x-auto pb-1 scrollbar-none pt-1 border-t border-slate-100">
          {categories.map((cat) => (
            <button
              key={cat}
              onClick={() => setCategoryFilter(cat)}
              className={`px-3 py-1.5 rounded-xl text-xs font-bold transition-all whitespace-nowrap ${
                categoryFilter === cat
                  ? 'bg-sky-600 text-white shadow-xs'
                  : 'bg-slate-100 text-slate-600 hover:bg-slate-200'
              }`}
            >
              {cat === 'all' ? 'جميع الفئات' : cat}
            </button>
          ))}
        </div>
      </div>

      {/* Inventory Items Table */}
      <div className="bg-white rounded-3xl border border-slate-200/90 shadow-xs overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-right text-xs">
            <thead className="bg-slate-50/90 border-b border-slate-200 text-slate-500 font-bold select-none">
              <tr>
                <th
                  onClick={() => toggleSort('name')}
                  className="py-3.5 px-4 cursor-pointer hover:text-slate-900 transition-colors"
                >
                  <div className="flex items-center gap-1.5">
                    <span>الصنف ورمز SKU</span>
                    <ArrowUpDown className="w-3.5 h-3.5 text-slate-400" />
                  </div>
                </th>
                <th className="py-3.5 px-4">الفئة / القسم</th>
                <th className="py-3.5 px-4">سعر الشراء</th>
                <th
                  onClick={() => toggleSort('sell_price')}
                  className="py-3.5 px-4 cursor-pointer hover:text-slate-900 transition-colors"
                >
                  <div className="flex items-center gap-1.5">
                    <span>سعر البيع</span>
                    <ArrowUpDown className="w-3.5 h-3.5 text-slate-400" />
                  </div>
                </th>
                <th
                  onClick={() => toggleSort('profit')}
                  className="py-3.5 px-4 cursor-pointer hover:text-slate-900 transition-colors"
                >
                  <div className="flex items-center gap-1.5">
                    <span>هامش الربح</span>
                    <ArrowUpDown className="w-3.5 h-3.5 text-slate-400" />
                  </div>
                </th>
                <th
                  onClick={() => toggleSort('quantity')}
                  className="py-3.5 px-4 cursor-pointer hover:text-slate-900 transition-colors"
                >
                  <div className="flex items-center gap-1.5">
                    <span>الرصيد المخزني</span>
                    <ArrowUpDown className="w-3.5 h-3.5 text-slate-400" />
                  </div>
                </th>
                <th className="py-3.5 px-4 text-center">تعديل سريع</th>
                <th className="py-3.5 px-4 text-left">إجراءات</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {filteredItems.length === 0 ? (
                <tr>
                  <td colSpan={8} className="py-16 text-center text-slate-400">
                    <Package className="w-10 h-10 mx-auto text-slate-300 stroke-1 mb-2" />
                    <p className="font-bold text-sm text-slate-600">لا توجد أصناف مطابقة للبحث</p>
                  </td>
                </tr>
              ) : (
                filteredItems.map((item) => {
                  const isOutOfStock = item.quantity <= 0;
                  const isLow = item.quantity > 0 && item.quantity <= (item.min_quantity || 3);
                  const marginAmount = (item.sell_price || 0) - (item.buy_price || 0);
                  const marginPercent =
                    item.buy_price > 0 ? Math.round((marginAmount / item.buy_price) * 100) : 0;

                  return (
                    <tr key={item.id} className="hover:bg-slate-50/70 transition-colors group">
                      {/* Name & SKU */}
                      <td className="py-3.5 px-4">
                        <div className="flex items-center gap-3">
                          <div className="w-9 h-9 rounded-xl bg-slate-100 text-slate-600 flex items-center justify-center shrink-0 group-hover:bg-sky-50 group-hover:text-sky-600 transition-colors">
                            <Package className="w-4 h-4" />
                          </div>
                          <div>
                            <div className="font-bold text-slate-900 text-xs sm:text-sm">
                              {item.name}
                            </div>
                            <div className="text-[10px] text-slate-400 font-mono flex items-center gap-1.5 mt-0.5">
                              {item.sku && <span>SKU: {item.sku}</span>}
                              <span>• الوحدة: {item.unit || 'حبة'}</span>
                            </div>
                          </div>
                        </div>
                      </td>

                      {/* Category */}
                      <td className="py-3.5 px-4">
                        <span className="text-[10px] font-bold px-2.5 py-1 rounded-lg bg-slate-100 text-slate-700">
                          {item.category || 'عام'}
                        </span>
                      </td>

                      {/* Buy Price */}
                      <td className="py-3.5 px-4 font-mono font-medium text-slate-500">
                        {item.buy_price?.toLocaleString() || 0} ر.ي
                      </td>

                      {/* Sell Price */}
                      <td className="py-3.5 px-4 font-mono font-bold text-slate-900 text-xs sm:text-sm">
                        {item.sell_price?.toLocaleString() || 0} ر.ي
                      </td>

                      {/* Profit Margin */}
                      <td className="py-3.5 px-4 font-mono">
                        <div className="flex items-center gap-1">
                          <span
                            className={`text-[10px] font-extrabold px-1.5 py-0.5 rounded-md ${
                              marginAmount > 0
                                ? 'bg-emerald-50 text-emerald-700'
                                : marginAmount < 0
                                ? 'bg-rose-50 text-rose-700'
                                : 'bg-slate-100 text-slate-600'
                            }`}
                          >
                            {marginAmount > 0 ? `+${marginAmount.toLocaleString()}` : marginAmount}{' '}
                            ر.ي
                          </span>
                          {marginPercent !== 0 && (
                            <span className="text-[9px] text-slate-400">({marginPercent}%)</span>
                          )}
                        </div>
                      </td>

                      {/* Stock Quantity */}
                      <td className="py-3.5 px-4 font-mono">
                        <div className="space-y-1">
                          <div className="flex items-center gap-1.5">
                            <span
                              className={`text-xs font-black ${
                                isOutOfStock
                                  ? 'text-rose-600'
                                  : isLow
                                  ? 'text-amber-600'
                                  : 'text-slate-900'
                              }`}
                            >
                              {item.quantity} {item.unit || 'حبة'}
                            </span>
                            <span
                              className={`text-[9px] font-bold px-1.5 py-0.2 rounded-full ${
                                isOutOfStock
                                  ? 'bg-rose-100 text-rose-700'
                                  : isLow
                                  ? 'bg-amber-100 text-amber-700'
                                  : 'bg-emerald-100 text-emerald-700'
                              }`}
                            >
                              {isOutOfStock ? 'نافد' : isLow ? 'منخفض' : 'متوفر'}
                            </span>
                          </div>

                          {/* Progress indicator */}
                          <div className="w-24 h-1.5 rounded-full bg-slate-100 overflow-hidden">
                            <div
                              className={`h-full rounded-full transition-all ${
                                isOutOfStock
                                  ? 'w-0'
                                  : isLow
                                  ? 'bg-amber-500 w-1/4'
                                  : 'bg-emerald-500 w-full'
                              }`}
                            />
                          </div>
                        </div>
                      </td>

                      {/* Inline Quick Stock Adjustments */}
                      <td className="py-3.5 px-4 text-center">
                        {canManageItems && (
                          <div className="inline-flex items-center gap-1 bg-slate-50 border border-slate-200/80 p-0.5 rounded-xl">
                            <button
                              type="button"
                              disabled={quickAdjustItemId === item.id}
                              onClick={() => handleQuickStockAdjust(item, -1)}
                              className="w-6 h-6 rounded-lg bg-white hover:bg-slate-200 text-slate-600 flex items-center justify-center transition-colors disabled:opacity-50"
                              title="صرف حبة (-1)"
                            >
                              -
                            </button>
                            <span className="w-8 text-center font-mono font-bold text-[11px] text-slate-700">
                              {quickAdjustItemId === item.id ? '...' : item.quantity}
                            </span>
                            <button
                              type="button"
                              disabled={quickAdjustItemId === item.id}
                              onClick={() => handleQuickStockAdjust(item, 1)}
                              className="w-6 h-6 rounded-lg bg-white hover:bg-slate-200 text-slate-600 flex items-center justify-center transition-colors disabled:opacity-50"
                              title="توريد حبة (+1)"
                            >
                              +
                            </button>
                          </div>
                        )}
                      </td>

                      {/* Actions */}
                      <td className="py-3.5 px-4 text-left">
                        <div className="flex items-center justify-end gap-1">
                          {canManageItems && (
                            <>
                              <button
                                onClick={() => onOpenItemModal(item)}
                                className="p-1.5 rounded-lg text-slate-400 hover:text-sky-600 hover:bg-sky-50 transition-colors"
                                title="تعديل تفاصيل الصنف"
                              >
                                <Edit2 className="w-3.5 h-3.5" />
                              </button>
                              <button
                                onClick={() => setDeleteItemTarget(item)}
                                className="p-1.5 rounded-lg text-slate-400 hover:text-rose-600 hover:bg-rose-50 transition-colors"
                                title="حذف الصنف"
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
    </div>
  );
};
