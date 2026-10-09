const { applicationDefault, initializeApp } = require('firebase-admin/app');
const { getAuth } = require('firebase-admin/auth');

const [uid, action = 'grant'] = process.argv.slice(2);
const projectId =
  process.env.GOOGLE_CLOUD_PROJECT ||
  process.env.GCLOUD_PROJECT ||
  'navoramapa';

if (!uid || !['grant', 'revoke'].includes(action)) {
  console.error(
    'Usage: node scripts/set_explore_admin_claim.cjs <firebase-auth-uid> [grant|revoke]',
  );
  process.exit(1);
}

async function main() {
  const app = initializeApp({
    credential: applicationDefault(),
    projectId,
  });

  const auth = getAuth(app);
  const user = await auth.getUser(uid);
  const claims = { ...user.customClaims };
  if (action === 'grant') {
    claims.admin = true;
  } else {
    delete claims.admin;
  }
  await auth.setCustomUserClaims(uid, claims);
  await app.delete();
  console.log(`Explore admin claim ${action}ed for ${uid} in ${projectId}.`);
}

main().catch((error) => {
  console.error(`Unable to ${action} Explore admin claim: ${error.message}`);
  process.exitCode = 1;
});
