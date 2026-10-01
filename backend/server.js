/**
 * LocalHub API - standalone Node backend for the IIS deployment.
 *
 * The original backend/index.ts targeted the AppDeploy platform SDK
 * (@appdeploy/sdk), which only exists on their hosting platform. This is a
 * dependency-free equivalent that serves the exact endpoints the React UI
 * calls, with the same seed catalogue.
 *
 * Listens on 127.0.0.1:8091 and is reverse-proxied by IIS on port 8080.
 */
import http from 'node:http';
import crypto from 'node:crypto';

const PORT = 8091;
const HOST = '127.0.0.1';

const products = [
  { name: 'Fresh Bananas',       category: 'Grocery',     price: 180,  unit: '1 dozen', store: 'Green Basket',    rating: 4.8, distance: 0.8, badge: 'Popular',   stock: 42 },
  { name: 'Basmati Rice',        category: 'Grocery',     price: 620,  unit: '5 kg',    store: 'Green Basket',    rating: 4.7, distance: 1.2, stock: 25 },
  { name: 'Chicken Biryani',     category: 'Food',        price: 420,  unit: '1 serving', store: 'Karachi Kitchen', rating: 4.9, distance: 1.5, badge: 'Top rated', stock: 30 },
  { name: 'Dishwashing Liquid',  category: 'Household',   price: 390,  unit: '750 ml',  store: 'Daily Mart',      rating: 4.6, distance: 2.1, stock: 50 },
  { name: 'Mixed Vegetables',    category: 'Grocery',     price: 260,  unit: '1 kg',    store: 'Fresh Corner',    rating: 4.7, distance: 1.0, stock: 40 },
  { name: 'Mineral Water',       category: 'Grocery',     price: 160,  unit: '6 x 1.5 L', store: 'Daily Mart',      rating: 4.5, distance: 1.8, stock: 80 },
  { name: 'Vitamin C Tablets',   category: 'Health',      price: 850,  unit: '30 tablets', store: 'Care Pharmacy', rating: 4.7, distance: 1.4, badge: 'Health',  stock: 20 },
  { name: 'USB-C Charger',       category: 'Marketplace', price: 1450, unit: 'New',     store: 'Tech Local',      rating: 4.5, distance: 2.7, stock: 12 },
  { name: 'Office Chair',        category: 'Marketplace', price: 8500, unit: 'Used',    store: 'Local Listings',  rating: 4.4, distance: 3.4, stock: 1 },
  { name: 'LED Bulb Pack',       category: 'Household',   price: 780,  unit: '4 pack',  store: 'Home Essentials', rating: 4.6, distance: 2.2, stock: 30 },
];

const services = [
  { title: 'Emergency Plumbing',  provider: 'Ahmed Plumbing Co.', category: 'Plumbing',   price: 800,  pricing: 'starting from', rating: 4.9, distance: 1.1, verified: true },
  { title: 'Home Electrical Repair', provider: 'PowerFix Services', category: 'Electrical', price: 700, pricing: 'starting from', rating: 4.8, distance: 2.0, verified: true },
  { title: 'AC Service & Repair', provider: 'CoolCare Technician', category: 'AC Repair', price: 1500, pricing: 'fixed visit', rating: 4.7, distance: 2.8, verified: true },
  { title: 'Deep Home Cleaning',  provider: 'CleanCrew Local',   category: 'Cleaning',   price: 2500, pricing: 'fixed price',  rating: 4.8, distance: 3.2, verified: false },
  { title: 'Car Mechanic Visit',  provider: 'AutoFix Mobile',    category: 'Mechanic',   price: 1200, pricing: 'starting from', rating: 4.7, distance: 4.1, verified: true },
];

// Attach stable ids and persist for the process lifetime.
const withIds = (rows) => rows.map((r) => ({ id: crypto.randomUUID(), ...r }));
const catalogue = withIds(products);
const serviceList = withIds(services);

const orders = [];
const user = { id: crypto.randomUUID(), name: 'LocalHub Demo Customer', email: 'customer@localhub.dev', role: 'CUSTOMER', verified: true };

const ROLES = ['CUSTOMER', 'SELLER', 'BUSINESS', 'SERVICE_PROVIDER', 'DELIVERY_PARTNER', 'ADMIN', 'SUPPORT_AGENT'];

function send(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body),
    'Access-Control-Allow-Origin': '*',
    'Cache-Control': 'no-store',
  });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve) => {
    let data = '';
    req.on('data', (c) => {
      data += c;
      if (data.length > 1e6) req.destroy();
    });
    req.on('end', () => {
      // Strip a UTF-8 BOM (some clients add one) before parsing.
      const raw = data.replace(/^\uFEFF/, '').trim();
      if (!raw) return resolve({});
      try {
        resolve(JSON.parse(raw));
      } catch {
        resolve({});
      }
    });
  });
}

/** Grounded assistant: only answers from the catalogue, never invents facts. */
function answer(prompt) {
  const q = String(prompt || '').toLowerCase().trim();
  if (!q) return 'Please ask about a product, service, budget or location.';

  const matchP = catalogue.filter((p) => (p.name + p.category + p.store).toLowerCase().includes(q));
  const matchS = serviceList.filter((s) => (s.title + s.category + s.provider).toLowerCase().includes(q));

  if (matchP.length) {
    return 'From the LocalHub catalogue: ' +
      matchP.map((p) => `${p.name} at ${p.store} - PKR ${p.price} (${p.unit}), ${p.distance} km away, rated ${p.rating}`).join('; ');
  }
  if (matchS.length) {
    return 'Local pros available: ' +
      matchS.map((s) => `${s.title} by ${s.provider} - from PKR ${s.price}, ${s.distance} km away, rated ${s.rating}${s.verified ? ' (verified)' : ''}`).join('; ');
  }
  if (/budget|cheap|affordable|under/.test(q)) {
    const sorted = [...catalogue].sort((a, b) => a.price - b.price).slice(0, 3);
    return 'Best value in stock: ' + sorted.map((p) => `${p.name} (PKR ${p.price}, ${p.store})`).join(', ') + '.';
  }
  if (/service|repair|plumb|clean|mechanic|ac\b/.test(q)) {
    return 'Available services: ' + serviceList.map((s) => `${s.title} from PKR ${s.price}`).join('; ') + '.';
  }
  return 'I could not match that in the LocalHub catalogue. You can browse Shop or Services, or tell me a product, service or budget.';
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  const path = url.pathname.replace(/\/+$/, '') || '/';

  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
    });
    return res.end();
  }

  try {
    // ---- health ----
    if (path === '/api/_healthcheck' || path === '/health') {
      return send(res, 200, { status: 'ok', service: 'LocalHub API', version: '1.0' });
    }

    // ---- catalogue ----
    if (path === '/api/products') {
      const q = String(url.searchParams.get('q') || '').toLowerCase();
      const list = q
        ? catalogue.filter((p) => (p.name + p.category + p.store).toLowerCase().includes(q))
        : catalogue;
      return send(res, 200, { products: list });
    }

    if (path === '/api/services') {
      const q = String(url.searchParams.get('q') || '').toLowerCase();
      const list = q
        ? serviceList.filter((s) => (s.title + s.category + s.provider).toLowerCase().includes(q))
        : serviceList;
      return send(res, 200, { services: list });
    }

    if (path === '/api/orders' && req.method === 'GET') {
      return send(res, 200, { orders });
    }

    if (path === '/api/me') {
      return send(res, 200, { user });
    }

    // ---- auth (development role switcher) ----
    if (path === '/api/auth/demo' && req.method === 'POST') {
      const body = await readBody(req);
      const role = String(body.role || 'CUSTOMER').toUpperCase();
      if (!ROLES.includes(role)) return send(res, 400, { error: 'Invalid role' });
      const created = {
        id: crypto.randomUUID(),
        name: role === 'CUSTOMER' ? 'LocalHub Customer' : role.replace(/_/g, ' '),
        email: role.toLowerCase() + '@localhub.dev',
        role,
        verified: true,
      };
      return send(res, 201, { user: created });
    }

    // ---- checkout (server-side totals) ----
    if (path === '/api/orders' && req.method === 'POST') {
      const body = await readBody(req);
      const items = Array.isArray(body.items) ? body.items : [];
      if (!items.length) return send(res, 400, { error: 'CART_EMPTY' });

      let subtotal = 0;
      const normalized = [];
      for (const item of items) {
        const p = catalogue.find((x) => x.id === item.productId);
        if (!p) return send(res, 400, { error: 'PRODUCT_NOT_FOUND' });
        const qty = Math.max(1, Math.min(50, Number(item.quantity || 1)));
        if ((p.stock ?? 0) < qty) return send(res, 409, { error: 'OUT_OF_STOCK' });
        subtotal += p.price * qty;
        normalized.push({ productId: p.id, name: p.name, quantity: qty, unitPrice: p.price });
      }

      const delivery = subtotal >= 3000 ? 0 : 150;
      const tax = Math.round(subtotal * 0.01);
      const order = {
        id: crypto.randomUUID(),
        itemCount: normalized.reduce((a, x) => a + x.quantity, 0),
        subtotal,
        deliveryFee: delivery,
        tax,
        total: subtotal + delivery + tax,
        paymentMethod: String(body.paymentMethod || 'COD'),
        status: 'CONFIRMED',
        createdAt: new Date().toISOString(),
        items: normalized,
      };
      orders.unshift(order);
      return send(res, 201, { order });
    }

    // ---- bookings ----
    if (path === '/api/bookings' && req.method === 'POST') {
      const body = await readBody(req);
      const id = String(body.serviceId || '');
      if (!id) return send(res, 400, { error: 'SERVICE_REQUIRED' });
      const s = serviceList.find((x) => x.id === id);
      if (!s) return send(res, 404, { error: 'SERVICE_NOT_FOUND' });
      const booking = {
        id: crypto.randomUUID(),
        serviceId: s.id,
        title: s.title,
        provider: s.provider,
        status: 'PENDING',
        requestedFor: String(body.requestedFor || 'NOW'),
        total: s.price,
        createdAt: new Date().toISOString(),
      };
      orders.unshift({
        id: booking.id,
        itemCount: 1,
        total: s.price,
        status: 'BOOKING_PENDING',
        createdAt: booking.createdAt,
        booking,
      });
      return send(res, 201, { booking });
    }

    // ---- grounded assistant ----
    if (path === '/api/ai/assistant' && req.method === 'POST') {
      const body = await readBody(req);
      const prompt = String(body.prompt || '').trim();
      if (!prompt) return send(res, 400, { error: 'PROMPT_REQUIRED' });
      return send(res, 200, { answer: answer(prompt) });
    }

    return send(res, 404, { error: 'NOT_FOUND', path });
  } catch (err) {
    console.error('request failed:', err);
    return send(res, 500, { error: 'INTERNAL_ERROR' });
  }
});

server.listen(PORT, HOST, () => {
  console.log(`LocalHub API listening on http://${HOST}:${PORT}`);
});

for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => server.close(() => process.exit(0)));
}
