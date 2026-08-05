// function/report-builder/src/index.ts

import { app, InvocationContext, Timer } from "@azure/functions";
import { DefaultAzureCredential } from "@azure/identity";
import { BlobServiceClient } from "@azure/storage-blob";
import { ResourceGraphClient } from "@azure/arm-resourcegraph";
import ExcelJS from "exceljs";
import { parse } from "csv-parse/sync";
import { EmailClient } from "@azure/communication-email";

const WASTE_QUERY = `
  Resources
  | where
      (type =~ 'microsoft.compute/disks' and properties.diskState =~ 'Unattached')
      or (type =~ 'microsoft.network/publicipaddresses' and properties.ipConfiguration == '')
      or (type =~ 'microsoft.compute/virtualmachines' and properties.extended.instanceView.powerState.code =~ 'PowerState/stopped')
  | project type, name, resourceGroup, sku = tostring(sku.name)
`;

export async function reportBuilder(myTimer: Timer, context: InvocationContext): Promise<void> {
  context.log("Building weekly Excel cost report.");

  const credential = new DefaultAzureCredential();
  const blobService = new BlobServiceClient(
    `https://${process.env["STORAGE_ACCOUNT_NAME"]}.blob.core.windows.net`,
    credential
  );

  const costRows = await readLatestCostExport(blobService);
  const wasteItems = await queryWasteItems(credential);

  const workbook = buildWorkbook(costRows, wasteItems);
  const buffer = await workbook.xlsx.writeBuffer();

  const reportName = `waste-report-${new Date().toISOString().slice(0, 10)}.xlsx`;
  const reportsContainer = blobService.getContainerClient("reports");
  await reportsContainer.createIfNotExists();
  await reportsContainer.getBlockBlobClient(reportName).uploadData(buffer);

  context.log(`Report saved: ${reportName}`);

  await sendReportReadyEmail(reportName, reportsContainer.getBlockBlobClient(reportName).url);
}

async function readLatestCostExport(blobService: BlobServiceClient): Promise<any[]> {
  const container = blobService.getContainerClient("cost-exports");
  let latestBlobName = "";
  let latestDate = new Date(0);

  for await (const blob of container.listBlobsFlat({ prefix: "exports/" })) {
    const modified = blob.properties.lastModified ?? new Date(0);
    if (modified > latestDate) {
      latestDate = modified;
      latestBlobName = blob.name;
    }
  }

  if (!latestBlobName) return [];

  const downloadResponse = await container.getBlockBlobClient(latestBlobName).download();
  const csvText = await streamToString(downloadResponse.readableStreamBody);
  return parse(csvText, { columns: true, skip_empty_lines: true });
}

async function queryWasteItems(credential: DefaultAzureCredential) {
  const graphClient = new ResourceGraphClient(credential);
  const result = await graphClient.resources({
    subscriptions: [process.env["SUBSCRIPTION_ID"]!],
    query: WASTE_QUERY,
  });
  return (result.data as any[]) ?? [];
}

function buildWorkbook(costRows: any[], wasteItems: any[]): ExcelJS.Workbook {
  const workbook = new ExcelJS.Workbook();
  workbook.creator = "Waste Detection Function";
  workbook.created = new Date();

  // --- Summary sheet ---
  const summary = workbook.addWorksheet("Summary");
  const totalActualCost = costRows.reduce((sum, row) => sum + (parseFloat(row.CostInBillingCurrency) || 0), 0);

  summary.columns = [
    { header: "Metric", key: "metric", width: 30 },
    { header: "Value", key: "value", width: 20 },
  ];
  summary.getRow(1).font = { bold: true };
  summary.addRows([
    { metric: "Report generated", value: new Date().toISOString().slice(0, 10) },
    { metric: "Total actual spend (last export)", value: `$${totalActualCost.toFixed(2)}` },
    { metric: "Waste items found", value: wasteItems.length },
  ]);

  // --- Waste detail sheet ---
  const detail = workbook.addWorksheet("Waste Findings");
  detail.columns = [
    { header: "Type", key: "type", width: 30 },
    { header: "Resource name", key: "name", width: 35 },
    { header: "Resource group", key: "resourceGroup", width: 30 },
    { header: "SKU / size", key: "sku", width: 20 },
  ];
  detail.getRow(1).font = { bold: true };
  detail.getRow(1).fill = {
    type: "pattern",
    pattern: "solid",
    fgColor: { argb: "FFD9E1F2" },
  };
  wasteItems.forEach((item) => {
    detail.addRow({
      type: item.type,
      name: item.name,
      resourceGroup: item.resourceGroup,
      sku: item.sku || "n/a",
    });
  });

  return workbook;
}

async function streamToString(readable: NodeJS.ReadableStream | undefined): Promise<string> {
  if (!readable) return "";
  const chunks: Buffer[] = [];
  for await (const chunk of readable) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }
  return Buffer.concat(chunks).toString("utf-8");
}

async function sendReportReadyEmail(reportName: string, blobUrl: string): Promise<void> {
  const credential = new DefaultAzureCredential();
  const emailClient = new EmailClient(process.env["ACS_ENDPOINT"]!, credential);

  await emailClient.beginSend({
    senderAddress: process.env["ACS_SENDER_ADDRESS"]!,
    content: {
      subject: `Weekly cost report ready - ${reportName}`,
      html: `
      <p>This week's cost and waste report has been generated.</p>
      <p><strong>File:</strong> ${reportName}</p>
      <p><a href="${blobUrl}">Open the report</a></p>
      <p><em>Note: this link requires access to the storage account - seeREADME for how to retrieve it if the link doesn't open directly. </em></p>
      `,
    },
    recipients: {
      to: [{ address: process.env["ALERT_EMAIL"]! }],
    },
  });
}

app.timer("reportBuilder", {
  schedule: "0 0 9 * * 2", // Tuesday 9 AM — a day after the Monday cost export
  handler: reportBuilder,
});