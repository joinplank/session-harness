export function GET() {
  return Response.json({ status: "ok", uptimeSeconds: process.uptime() });
}
