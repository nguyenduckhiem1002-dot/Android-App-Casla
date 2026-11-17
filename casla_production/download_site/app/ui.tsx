// Logo và icon dùng chung. Icon đi kèm chữ nên đều aria-hidden.

const GOLD = '#C39D56';
const STAR_PATH =
  'M91.4,38.1c1.2-7.7,4.6-12.1,11.3-14.5C96.1,21.1,92.6,16.7,91.4,9c-1.2,7.6-4.7,12.1-11.5,14.5C86.7,25.9,90.3,30.5,91.4,38.1z';

/** Chữ CASLA lấy từ assets/images/logo.svg; phần chữ theo màu `currentColor`. */
export function Logo({ className }: { className?: string }) {
  return (
    <svg className={className} viewBox="4 6 294 91" role="img" aria-label="CASLA">
      <g fill="currentColor">
        <path d="M54.7,83.8C49.2,90.7,41.5,94,33.5,94C18.7,94,6.9,82.7,6.9,68.1s11.8-25.9,26.7-25.9c7.9,0,15.7,3.2,21.2,10.2l-7.6,5.7c-3.2-4.6-8-7.2-13.6-7.2c-8.9,0-17,7.5-17,17.2s8.1,17.2,17,17.2c5.6,0,10.6-2.6,13.8-6.9L54.7,83.8z" />
        <path d="M135.8,78.6c3.7,4,8.9,6.7,14.7,6.7c7-0.1,11.9-2.7,11.9-7.4c0-11.1-32-0.4-32-20.6c0-8.9,9.3-14.9,20.6-14.9c8.2,0,14.9,2.6,19.8,7.6l-6.8,6.1c-4.5-4.4-8.6-5.9-13.4-5.9c-7.6,0-10.4,3.7-10.4,6.7c0,11.2,32,0,32,20.6c0,10.4-10.5,16.6-21.9,16.6c-7,0-15-2.6-21.3-9.2L135.8,78.6z" />
        <polygon points="213.8,84.3 194.3,84.3 194.3,43.3 185.1,43.3 185.1,93 223,93 223,84.3" />
        <polygon points="245.3,93 264.9,59.1 284.4,93 295.1,93 264.9,40.6 234.7,93" />
      </g>
      <g fill={GOLD}>
        <polygon points="71.8,93 91.4,59.1 110.9,93 121.6,93 91.4,40.6 61.2,93" />
        <path d={STAR_PATH} />
      </g>
    </svg>
  );
}

/** Ngôi sao của logo, dùng làm họa tiết nền. */
export function StarMark({ className }: { className?: string }) {
  return (
    <svg className={className} viewBox="79 8 25 31" aria-hidden="true" focusable="false">
      <path d={STAR_PATH} fill="currentColor" />
    </svg>
  );
}

function Icon({ children, className }: { children: React.ReactNode; className?: string }) {
  return (
    <svg
      className={className}
      viewBox="0 0 24 24"
      width="24"
      height="24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      {children}
    </svg>
  );
}

export function DownloadIcon({ className }: { className?: string }) {
  return (
    <Icon className={className}>
      <path d="M12 3v12" />
      <path d="m7 10 5 5 5-5" />
      <path d="M5 21h14" />
    </Icon>
  );
}
