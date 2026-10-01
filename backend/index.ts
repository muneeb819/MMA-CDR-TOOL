import { router, json, error, db, ai } from '@appdeploy/sdk';

type Product={name:string;category:string;price:number;unit:string;store:string;rating:number;distance:number;badge?:string;stock?:number};
type Service={title:string;provider:string;category:string;price:number;pricing:string;rating:number;distance:number;verified:boolean};

const products:Product[]=[
{name:'Fresh Bananas',category:'Grocery',price:180,unit:'1 dozen',store:'Green Basket',rating:4.8,distance:.8,badge:'Popular',stock:42},
{name:'Basmati Rice',category:'Grocery',price:620,unit:'5 kg',store:'Green Basket',rating:4.7,distance:1.2,stock:25},
{name:'Chicken Biryani',category:'Food',price:420,unit:'1 serving',store:'Karachi Kitchen',rating:4.9,distance:1.5,badge:'Top rated',stock:30},
{name:'Dishwashing Liquid',category:'Household',price:390,unit:'750 ml',store:'Daily Mart',rating:4.6,distance:2.1,stock:50},
{name:'Mixed Vegetables',category:'Grocery',price:260,unit:'1 kg',store:'Fresh Corner',rating:4.7,distance:1,stock:40},
{name:'Mineral Water',category:'Grocery',price:160,unit:'6 × 1.5 L',store:'Daily Mart',rating:4.5,distance:1.8,stock:80},
{name:'Vitamin C Tablets',category:'Health',price:850,unit:'30 tablets',store:'Care Pharmacy',rating:4.7,distance:1.4,badge:'Health',stock:20},
{name:'USB-C Charger',category:'Marketplace',price:1450,unit:'New',store:'Tech Local',rating:4.5,distance:2.7,stock:12},
{name:'Office Chair',category:'Marketplace',price:8500,unit:'Used',store:'Local Listings',rating:4.4,distance:3.4,stock:1},
{name:'LED Bulb Pack',category:'Household',price:780,unit:'4 pack',store:'Home Essentials',rating:4.6,distance:2.2,stock:30}
];
const services:Service[]=[
{title:'Emergency Plumbing',provider:'Ahmed Plumbing Co.',category:'Plumbing',price:800,pricing:'starting from',rating:4.9,distance:1.1,verified:true},
{title:'Home Electrical Repair',provider:'PowerFix Services',category:'Electrical',price:700,pricing:'starting from',rating:4.8,distance:2,verified:true},
{title:'AC Service & Repair',provider:'CoolCare Technician',category:'AC Repair',price:1500,pricing:'fixed visit',rating:4.7,distance:2.8,verified:true},
{title:'Deep Home Cleaning',provider:'CleanCrew Local',category:'Cleaning',price:2500,pricing:'fixed price',rating:4.8,distance:3.2,verified:false},
{title:'Car Mechanic Visit',provider:'AutoFix Mobile',category:'Mechanic',price:1200,pricing:'starting from',rating:4.7,distance:4.1,verified:true}
];
async function seed<T>(table:string,data:T[]){const x=await db.list<T>(table,{limit:100});if(x.items.length)return x.items;await db.add(table,data as Array<Record<string,unknown>>);return (await db.list<T>(table,{limit:100})).items}
export const handler=router({
'GET /api/_healthcheck':[async()=>json({status:'ok',service:'LocalHub API',version:'1.0'})],
'GET /api/me':[async()=>{const x=await seed('users',[{name:'LocalHub Demo Customer',email:'customer@localhub.dev',role:'CUSTOMER',verified:true}]);return json({user:x[0]})}],
'POST /api/auth/demo':[async({body})=>{const role=String((body as any)?.role||'CUSTOMER');const allowed=['CUSTOMER','SELLER','BUSINESS','SERVICE_PROVIDER','DELIVERY_PARTNER','ADMIN','SUPPORT_AGENT'];if(!allowed.includes(role))return error('Invalid role',400);const name=role==='CUSTOMER'?'LocalHub Customer':role.replaceAll('_',' ');const user={name,email:role.toLowerCase()+'@localhub.dev',role,verified:role!=='CUSTOMER'||true};const [id]=await db.add('users',[user]);return json({user:{id,...user}},201)}],
'GET /api/products':[async({query})=>{const x=await seed<Product>('products',products);const q=String(query.q||'').toLowerCase();return json({products:q?x.filter(p=>(p.name+p.category+p.store).toLowerCase().includes(q)):x})}],
'GET /api/services':[async({query})=>{const x=await seed<Service>('services',services);const q=String(query.q||'').toLowerCase();return json({services:q?x.filter(s=>(s.title+s.category+s.provider).toLowerCase().includes(q)):x})}],
'GET /api/orders':[async()=>{const x=await db.list('orders',{limit:100});return json({orders:x.items})}],
'POST /api/orders':[async({body})=>{const input=(body||{}) as any;if(!Array.isArray(input.items)||!input.items.length)return error('CART_EMPTY',400);const catalog=await seed<Product>('products',products);let subtotal=0;const normalized=[];for(const item of input.items){const p=catalog.find((x:any)=>x.id===item.productId);const qty=Math.max(1,Math.min(50,Number(item.quantity||1)));if(!p)return error('PRODUCT_NOT_FOUND',400);if((p.stock??0)<qty)return error('OUT_OF_STOCK',409);subtotal+=p.price*qty;normalized.push({productId:p.id,name:p.name,quantity:qty,unitPrice:p.price})}const delivery=subtotal>=3000?0:150;const tax=Math.round(subtotal*.01);const total=subtotal+delivery+tax;const order={itemCount:normalized.reduce((a,x)=>a+x.quantity,0),subtotal,deliveryFee:delivery,tax,total,paymentMethod:String(input.paymentMethod||'COD'),status:'CONFIRMED',createdAt:new Date().toISOString(),items:normalized};const [id]=await db.add('orders',[order]);return json({order:{id,...order}},201)}],
'POST /api/bookings':[async({body})=>{const id=String((body as any)?.serviceId||'');if(!id)return error('SERVICE_REQUIRED',400);const x=await seed<Service>('services',services);const s=x.find((a:any)=>a.id===id);if(!s)return error('SERVICE_NOT_FOUND',404);const booking={serviceId:id,title:s.title,provider:s.provider,status:'PENDING',requestedFor:String((body as any)?.requestedFor||'NOW'),total:s.price,createdAt:new Date().toISOString()};const [oid]=await db.add('orders',[{itemCount:1,total:s.price,status:'BOOKING_PENDING',createdAt:booking.createdAt,booking}]);return json({booking:{id:oid,...booking}},201)}],
'POST /api/ai/assistant':[async({body})=>{const prompt=String((body as any)?.prompt||'').trim();if(!prompt)return error('PROMPT_REQUIRED',400);const p=await seed<Product>('products',products);const s=await seed<Service>('services',services);const result=await ai.run({system:'You are LocalHub AI. Answer only from the supplied catalog. Never invent prices, inventory, providers or availability. If information is missing, say so and ask one concise question. Never claim a transaction occurred.',prompt:JSON.stringify({request:prompt,products:p,services:s}),maxSteps:3,maxTokens:350,thinkingMode:'FAST'});return json({answer:result.text})}]
});