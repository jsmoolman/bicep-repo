const yaml = require('js-yaml');
const fs = require('fs');

const files = process.argv.slice(2);
let ok = true;
for (const f of files) {
  try {
    const text = fs.readFileSync(f, 'utf8');
    const doc = yaml.load(text);
    console.log(`OK: ${f} parsed successfully.`);
    // Basic structural sanity checks for ADO pipeline shape
    if (typeof doc !== 'object' || doc === null) {
      console.log(`  WARN: top-level document in ${f} is not an object.`);
    } else {
      const topKeys = Object.keys(doc);
      console.log(`  top-level keys: ${topKeys.join(', ')}`);
    }
  } catch (e) {
    ok = false;
    console.log(`FAIL: ${f} failed to parse: ${e.message}`);
  }
}
process.exit(ok ? 0 : 1);
