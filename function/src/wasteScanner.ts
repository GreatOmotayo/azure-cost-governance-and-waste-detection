import { app, InvocationContext, Timer } from "@azure/functions";
import { DefaultAzureCredential } from "@azure/identity";
import { ResourceGraphClient } from "@azure/arm-resourcegraph";
import { EmailClient } from "@azure/communication-email";

interface WasteItem {
  type: "orphaned-disk" | "orphaned-public-ip" | "stopped-not-deallocated-vm";
  name: string;
  resourceGroup: string;
  sku: string;
  estimatedMonthlyCost: number;
}

// One Resource Graph query covering all three waste patterns.
// Kept as a single query rather than three separate calls — see decision notes below.

const WASTE_QUERY = `
  Resources
  | where
      (type =~ 'microsoft.compute/disks' and properties.diskState =~ 'Unattached')
      or (type =~ 'microsoft.network/publicipaddresses' and properties.ipConfiguration == '')
      or (type =~ 'microsoft.compute/virtualmachines' and properties.extended.instanceView.powerState.code =~ 'PowerState/stopped')
  | project
      type,
      name,
      resourceGroup,
      sku = tostring(sku.name),
      vmSize = tostring(properties.hardwareProfile.vmSize),
      diskSizeGb = tostring(properties.diskSizeGB)
`;

export async function wasteScanner(myTimer: Timer, context: InvocationContext): Promise<void> {
  context.log("Weekly waste-scan starting.");

  const credential = new DefaultAzureCredential();
  const subscriptionId = process.env["SUBSCRIPTION_ID"]!;

  const graphClient = new ResourceGraphClient(credential);
  const queryResult = await graphClient.resources({
    subscriptions: [subscriptionId],
    query: WASTE_QUERY,
  });

  const rows = (queryResult.data as any[]) ?? [];
  const wasteItems: WasteItem[] = [];

  for (const row of rows) {
    const monthlyCost = await estimateMonthlyCost(row);
    wasteItems.push({
      type: mapResourceType(row.type),
      name: row.name,
      resourceGroup: row.resourceGroup,
      sku: row.vmSize || row.sku || "n/a",
      estimatedMonthlyCost: monthlyCost,
    });
  }

  const totalSavings = wasteItems.reduce((sum, item) => sum + item.estimatedMonthlyCost, 0);

  context.log(`Found ${wasteItems.length} waste item(s), estimated $${totalSavings.toFixed(2)}/month.`);

  await sendReportEmail(wasteItems, totalSavings);
}

function mapResourceType(azureType: string): WasteItem["type"] {
  if (azureType.includes("disks")) return "orphaned-disk";
  if (azureType.includes("publicipaddresses")) return "orphaned-public-ip";
  return "stopped-not-deallocated-vm";
}

// Calls Azure's public Retail Prices API — no authentication required.
// Falls back to a conservative flat estimate if a lookup ever fails,
// so one bad API call never crashes the whole weekly report.
async function estimateMonthlyCost(row: any): Promise<number> {
  try {
    const filter = row.vmSize
      ? `armSkuName eq '${row.vmSize}' and priceType eq 'Consumption'`
      : `skuName eq '${row.sku}' and priceType eq 'Consumption'`;

    const url = `https://prices.azure.com/api/retail/prices?$filter=${encodeURIComponent(filter)}`;
    const response = await fetch(url);
    const data = (await response.json()) as { Items: { retailPrice: number }[] };

    const hourlyPrice = data.Items?.[0]?.retailPrice ?? 0.02; // conservative fallback
    return hourlyPrice * 730; // ~730 hours in an average month
  } catch {
    return 15; // flat fallback estimate if pricing lookup fails entirely
  }
}

async function sendReportEmail(items: WasteItem[], totalSavings: number): Promise<void> {
  const credential = new DefaultAzureCredential();
  const emailClient = new EmailClient(process.env["ACS_ENDPOINT"]!, credential);

  const rows = items
    .map(
      (item) =>
        `<tr><td>${item.type}</td><td>${item.name}</td><td>${item.resourceGroup}</td><td>$${item.estimatedMonthlyCost.toFixed(2)}</td></tr>`
    )
    .join("");

  const htmlBody = `
    <h2>Weekly Waste Scan Report</h2>
    <p><strong>Total estimated monthly waste: $${totalSavings.toFixed(2)}</strong></p>
    <table border="1" cellpadding="6" style="border-collapse:collapse;">
      <tr><th>Type</th><th>Resource</th><th>Resource Group</th><th>Est. Monthly Cost</th></tr>
      ${rows}
    </table>
  `;

  await emailClient.beginSend({
    senderAddress: process.env["ACS_SENDER_ADDRESS"]!,
    content: {
      subject: `Weekly Waste Report — $${totalSavings.toFixed(2)}/month found`,
      html: htmlBody,
    },
    recipients: {
      to: [{ address: process.env["ALERT_EMAIL"]! }],
    },
  });
}

app.timer("wasteScanner", {
  schedule: "0 */10 * * * *", // Every 10 minutes for testing; change to "0 0 8 * * 1" for production (Monday 8 AM)
  handler: wasteScanner,
});

