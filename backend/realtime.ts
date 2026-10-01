import { db } from '@appdeploy/sdk';

export const realtime = async (event: any) => {
  let message: any = {};
  try {
    message = JSON.parse(event.body || '{}');
  } catch {}
  if (
    message.type === 'system.disconnected' &&
    message.payload?.connection_id
  ) {
    const page = await db.list('entity_subscriptions', { limit: 1000 });
    const ids = page.items
      .filter(item => item.connection_id === message.payload.connection_id)
      .map(item => item.id);
    if (ids.length) await db.delete('entity_subscriptions', ids);
  }
  return { statusCode: 200 };
};
