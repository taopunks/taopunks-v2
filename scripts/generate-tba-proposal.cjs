const puppeteer = require("puppeteer");
const path = require("path");
const fs = require("fs");

(async () => {
  const htmlPath = path.join(__dirname, "tba-proposal.html");
  const outPath = path.join(__dirname, "..", "TaoPunks_TBA_Proposal.pdf");

  const browser = await puppeteer.launch({ headless: true });
  const page = await browser.newPage();
  await page.goto("file:///" + htmlPath.replace(/\\/g, "/"), {
    waitUntil: "networkidle0",
  });
  await page.pdf({
    path: outPath,
    format: "A4",
    printBackground: true,
    margin: { top: "20mm", bottom: "20mm", left: "18mm", right: "18mm" },
  });
  await browser.close();
  console.log("PDF generated:", outPath);
})();
